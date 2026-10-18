//! Plain-C bridge over the RaTeX math engine. The contract is documented in
//! `include/ratex_bridge.h`.
//!
//! Every exported function runs its whole body inside `catch_unwind`, so a
//! Rust panic never crosses the C boundary: it is reported as NULL / -1 and
//! described by `ratex_bridge_last_error()`.

#[cfg(panic = "abort")]
compile_error!("ratex_bridge must be built with panic = \"unwind\": its C entry points catch panics");

use std::cell::RefCell;
use std::collections::HashMap;
use std::ffi::{c_char, c_int, c_void, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use ab_glyph::{Font, FontRef};
use ratex_cairo::{render_to_cairo, CairoOptions};
use ratex_layout::{
    layout_with_fallback_metrics, to_display_list, validate_layout, FallbackGlyphMetrics,
    LayoutOptions,
};
use ratex_parser::parse;
use ratex_types::color::Color;
use ratex_types::math_style::MathStyle;
use ratex_types::path_command::PathCommand;
use ratex_types::{DisplayItem, DisplayList};

/// Longest TeX source the bridge accepts. Some constructs (`\ce` in
/// particular) parse in quadratic time, so the app caps formulas well below
/// this; the bridge only guards against pathological input.
const MAX_TEX_BYTES: usize = 8 * 1024;

/// Largest box, in pixels, the bridge hands out. Anything bigger is a
/// deliberately absurd formula (`\hspace{1e9pt}`) that would overflow Pango
/// units or cairo surfaces downstream.
const MAX_BOX_PX: f64 = 16_384.0;

/// Most memory, in estimated bytes, one formula may keep. Stretchy
/// constructs (`\overbrace`, `\xrightarrow`) are drawn as long paths, tens
/// of kilobytes each, so a short formula could otherwise hold megabytes.
/// Also `RATEX_BRIDGE_MAX_FORMULA_BYTES` in the header.
const MAX_FORMULA_BYTES: usize = 512 * 1024;

/// Most memory, in estimated bytes, all live formulas together may keep by
/// default; past it new formulas are refused until some are freed.
const DEFAULT_LIVE_BYTES_LIMIT: usize = 192 * 1024 * 1024;

static LIVE_BYTES: AtomicUsize = AtomicUsize::new(0);
static LIVE_BYTES_LIMIT: AtomicUsize = AtomicUsize::new(DEFAULT_LIVE_BYTES_LIMIT);

// ---------------------------------------------------------------------------
// Thread-local last error
// ---------------------------------------------------------------------------

thread_local! {
    static LAST_ERROR: RefCell<Option<CString>> = const { RefCell::new(None) };
    /// Whether the last error was the memory limit, which may pass later.
    static LAST_ERROR_IS_TRANSIENT: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

fn set_last_error_transient(transient: bool) {
    let _ = LAST_ERROR_IS_TRANSIENT.try_with(|cell| cell.set(transient));
}

fn set_last_error(message: &str) {
    let bytes: Vec<u8> = message.bytes().filter(|&b| b != 0).collect();
    let stored = CString::new(bytes).ok();
    // try_with: during thread teardown the slot may already be gone, and
    // panicking there would abort the process.
    let _ = LAST_ERROR.try_with(|cell| {
        if let Ok(mut slot) = cell.try_borrow_mut() {
            *slot = stored;
        }
    });
}

fn clear_last_error() {
    set_last_error_transient(false);
    let _ = LAST_ERROR.try_with(|cell| {
        if let Ok(mut slot) = cell.try_borrow_mut() {
            *slot = None;
        }
    });
}

fn panic_message(payload: &(dyn std::any::Any + Send)) -> String {
    if let Some(text) = payload.downcast_ref::<&str>() {
        (*text).to_string()
    } else if let Some(text) = payload.downcast_ref::<String>() {
        text.clone()
    } else {
        "unknown panic".to_string()
    }
}

/// Runs `body` with panics caught. A panic becomes `fallback` plus a last
/// error; recording that error is itself panic-free.
fn guarded<T>(fallback: T, body: impl FnOnce() -> T) -> T {
    match catch_unwind(AssertUnwindSafe(|| {
        clear_last_error();
        body()
    })) {
        Ok(value) => value,
        Err(payload) => {
            let message = catch_unwind(AssertUnwindSafe(|| panic_message(payload.as_ref())))
                .unwrap_or_else(|_| "panic".to_string());
            let _ = catch_unwind(AssertUnwindSafe(|| set_last_error(&format!("panic: {message}"))));
            fallback
        }
    }
}

// ---------------------------------------------------------------------------
// Formula
// ---------------------------------------------------------------------------

/// The default colour a formula is laid out with, standing in for the
/// colour it is drawn with. `\color` values come from 8-bit components or
/// names, which never land on these fractions.
const DEFAULT_COLOR_STAND_IN: Color = Color { r: 1.0 / 512.0, g: 3.0 / 512.0, b: 5.0 / 512.0, a: 1.0 };

/// A laid-out formula. It keeps only its display list, in the colour it was
/// last drawn in, and which items take the default colour (the theme can
/// change between draws); the parse tree, which macros can make far larger
/// than the drawing, is not kept.
pub struct Formula {
    list: Mutex<(Color, DisplayList)>,
    /// Per item: whether it is drawn in the default colour.
    default_colored: Vec<bool>,
    font_px: f64,
    width: f64,
    height: f64,
    depth: f64,
    /// The bytes this formula holds of the live total.
    cost: usize,
}

impl Drop for Formula {
    fn drop(&mut self) {
        LIVE_BYTES.fetch_sub(self.cost, Ordering::Relaxed);
    }
}

fn item_color(item: &mut DisplayItem) -> &mut Color {
    match item {
        DisplayItem::GlyphPath { color, .. }
        | DisplayItem::Line { color, .. }
        | DisplayItem::Rect { color, .. }
        | DisplayItem::Path { color, .. } => color,
    }
}

/// Heap bytes of a display list, near enough; paths dominate.
fn display_list_bytes(list: &DisplayList) -> usize {
    let mut bytes = std::mem::size_of::<DisplayList>() + list.items.capacity() * std::mem::size_of::<DisplayItem>();
    for item in &list.items {
        match item {
            DisplayItem::GlyphPath { font, .. } => bytes += font.capacity(),
            DisplayItem::Path { commands, .. } => bytes += commands.capacity() * std::mem::size_of::<PathCommand>(),
            _ => {}
        }
    }
    bytes
}

impl Formula {
    /// Runs `body` with the display list in `color`, recolouring the
    /// default-coloured items first if the colour changed.
    fn with_display_list<T>(&self, color: Color, body: impl FnOnce(&DisplayList) -> T) -> T {
        let mut guard = self.list.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let (current, list) = &mut *guard;
        if *current != color {
            for (item, &is_default) in list.items.iter_mut().zip(&self.default_colored) {
                if is_default {
                    *item_color(item) = color;
                }
            }
            *current = color;
        }
        body(list)
    }
}

/// Metrics, in em, for every non-ASCII character of `tex` that the system
/// fallback font has. RaTeX draws characters the KaTeX fonts lack with that
/// same font, so measuring there keeps advance widths and drawn glyphs in
/// step (characters KaTeX does cover ignore these entries).
fn fallback_metrics(tex: &str) -> HashMap<char, FallbackGlyphMetrics> {
    let mut metrics = HashMap::new();
    if tex.is_ascii() {
        return metrics;
    }
    let Some(data) = ratex_unicode_font::unicode_font_data_ref() else {
        return metrics;
    };
    let index = ratex_unicode_font::unicode_font_face_index().unwrap_or(0);
    let Ok(font) = FontRef::try_from_slice_and_index(data.as_slice(), index) else {
        return metrics;
    };
    let units_per_em = font.units_per_em().unwrap_or(1000.0);
    if units_per_em <= 0.0 {
        return metrics;
    }
    for ch in tex.chars().filter(|ch| !ch.is_ascii()) {
        if metrics.contains_key(&ch) {
            continue;
        }
        let glyph = font.glyph_id(ch);
        if glyph.0 == 0 {
            continue;
        }
        let width = f64::from(font.h_advance_unscaled(glyph) / units_per_em);
        // ab_glyph's outline bounds keep the font's y_max in `min.y` and its
        // y_min in `max.y` (screen orientation), so the top is `min.y`.
        let (height, depth) = match font.outline(glyph) {
            Some(outline) => (
                f64::from((outline.bounds.min.y / units_per_em).max(0.0)),
                f64::from((-outline.bounds.max.y / units_per_em).max(0.0)),
            ),
            None => (0.0, 0.0),
        };
        if width.is_finite() && height.is_finite() && depth.is_finite() {
            metrics.insert(ch, FallbackGlyphMetrics { width, height, depth });
        }
    }
    metrics
}

fn parse_formula(tex: &str, display: bool, font_px: f64) -> Result<Formula, String> {
    if tex.len() > MAX_TEX_BYTES {
        return Err(format!("formula is longer than {MAX_TEX_BYTES} bytes"));
    }
    if !font_px.is_finite() || !(1.0..=1024.0).contains(&font_px) {
        return Err(format!("font size {font_px} is outside 1…1024 px"));
    }
    if LIVE_BYTES.load(Ordering::Relaxed) >= LIVE_BYTES_LIMIT.load(Ordering::Relaxed) {
        set_last_error_transient(true);
        return Err("formula memory limit reached".to_string());
    }
    let nodes = parse(tex).map_err(|error| format!("parse error: {error}"))?;
    let style = if display { MathStyle::Display } else { MathStyle::Text };
    let options = LayoutOptions::default().with_style(style).with_color(DEFAULT_COLOR_STAND_IN);
    let tree = layout_with_fallback_metrics(&nodes, &options, Arc::new(fallback_metrics(tex)));
    validate_layout(&tree).map_err(|error| format!("layout rejected: {error}"))?;
    let mut list = to_display_list(&tree);
    // The tree and the layout are dropped here; only the list stays.
    drop(tree);
    drop(nodes);
    let default_colored: Vec<bool> = list.items.iter_mut().map(|item| *item_color(item) == DEFAULT_COLOR_STAND_IN).collect();
    let width = list.width * font_px;
    let height = (list.height + list.depth) * font_px;
    let depth = list.depth * font_px;
    let sane = |value: f64| value.is_finite() && (0.0..=MAX_BOX_PX).contains(&value);
    if !sane(width) || !sane(height) || !sane(depth) || depth > height {
        return Err(format!("formula box {width}×{height} px is out of range"));
    }
    let cost = display_list_bytes(&list) + default_colored.capacity() + 1024;
    if cost > MAX_FORMULA_BYTES {
        return Err(format!("formula needs about {} KiB, more than {} KiB", cost / 1024, MAX_FORMULA_BYTES / 1024));
    }
    let limit = LIVE_BYTES_LIMIT.load(Ordering::Relaxed);
    if LIVE_BYTES
        .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |live| live.checked_add(cost).filter(|total| *total <= limit))
        .is_err()
    {
        set_last_error_transient(true);
        return Err("formula memory limit reached".to_string());
    }
    Ok(Formula {
        list: Mutex::new((DEFAULT_COLOR_STAND_IN, list)),
        default_colored,
        font_px,
        width,
        height,
        depth,
        cost,
    })
}

// ---------------------------------------------------------------------------
// Text fallback font
// ---------------------------------------------------------------------------

// fontconfig is already in the process on Linux (Pango and cairo use it); these are
// the few calls needed to ask it for a font.
#[cfg(not(target_os = "macos"))]
#[link(name = "fontconfig")]
extern "C" {
    fn FcNameParse(name: *const u8) -> *mut c_void;
    fn FcConfigSubstitute(config: *mut c_void, pattern: *mut c_void, kind: c_int) -> c_int;
    fn FcDefaultSubstitute(pattern: *mut c_void);
    fn FcFontMatch(config: *mut c_void, pattern: *mut c_void, result: *mut c_int) -> *mut c_void;
    fn FcPatternGetString(pattern: *const c_void, object: *const c_char, n: c_int, value: *mut *mut u8) -> c_int;
    fn FcPatternGetInteger(pattern: *const c_void, object: *const c_char, n: c_int, value: *mut c_int) -> c_int;
    fn FcPatternGetCharSet(pattern: *const c_void, object: *const c_char, n: c_int, value: *mut *mut c_void) -> c_int;
    fn FcCharSetHasChar(charset: *const c_void, ucs4: u32) -> c_int;
    fn FcPatternDestroy(pattern: *mut c_void);
}

#[cfg(not(target_os = "macos"))]
const FC_MATCH_PATTERN: c_int = 0;
#[cfg(not(target_os = "macos"))]
const FC_RESULT_MATCH: c_int = 0;

/// The serif system font fontconfig picks for Russian text, as a RaTeX font
/// spec (`path` or `path#index`), if it also has Greek. RaTeX draws text the
/// KaTeX fonts lack (`\text{Площадь}`) with one system font; left to itself
/// it looks for Noto Sans CJK at a fixed path (absent in Flatpak runtimes)
/// and then guesses by locale. A serif with Cyrillic and Greek matches
/// KaTeX's own text font far better.
#[cfg(not(target_os = "macos"))]
fn text_fallback_font_spec() -> Option<String> {
    // SAFETY: plain fontconfig calls on the default configuration; every
    // pattern created here is destroyed before returning.
    unsafe {
        let pattern = FcNameParse(c"serif:lang=ru".as_ptr().cast());
        if pattern.is_null() {
            return None;
        }
        FcConfigSubstitute(std::ptr::null_mut(), pattern, FC_MATCH_PATTERN);
        FcDefaultSubstitute(pattern);
        let mut result: c_int = 0;
        let matched = FcFontMatch(std::ptr::null_mut(), pattern, &mut result);
        FcPatternDestroy(pattern);
        if matched.is_null() {
            return None;
        }
        let mut file: *mut u8 = std::ptr::null_mut();
        let mut index: c_int = 0;
        let mut charset: *mut c_void = std::ptr::null_mut();
        let has_file = FcPatternGetString(matched, c"file".as_ptr(), 0, &mut file) == FC_RESULT_MATCH && !file.is_null();
        // The charset belongs to the pattern: check it before destroying that.
        let has_glyphs = FcPatternGetCharSet(matched, c"charset".as_ptr(), 0, &mut charset) == FC_RESULT_MATCH
            && !charset.is_null()
            && FcCharSetHasChar(charset, u32::from('ж')) != 0
            && FcCharSetHasChar(charset, u32::from('α')) != 0;
        // RaTeX splits its spec at the last `#`, so a path holding one (or
        // one that is not UTF-8) cannot be passed on.
        let path = (has_file && has_glyphs)
            .then(|| std::ffi::CStr::from_ptr(file.cast()).to_str().ok().map(str::to_owned))
            .flatten()
            .filter(|path| !path.contains('#'));
        if FcPatternGetInteger(matched, c"index".as_ptr(), 0, &mut index) != FC_RESULT_MATCH {
            index = 0;
        }
        FcPatternDestroy(matched);
        let path = path?;
        Some(if index == 0 { path } else { format!("{path}#{index}") })
    }
}

/// Pango does not use fontconfig on macOS, and RaTeX finds Arial Unicode
/// there by itself.
#[cfg(target_os = "macos")]
fn text_fallback_font_spec() -> Option<String> {
    None
}

// ---------------------------------------------------------------------------
// C API
// ---------------------------------------------------------------------------

/// The font RaTeX should draw text with that its own fonts lack, as the value
/// for the `RATEX_UNICODE_FONT` environment variable, or NULL to leave RaTeX
/// to its own discovery. The string lives for the rest of the process.
#[no_mangle]
pub extern "C" fn ratex_bridge_text_fallback_font() -> *const c_char {
    static SPEC: OnceLock<Option<CString>> = OnceLock::new();
    guarded(std::ptr::null(), || {
        SPEC.get_or_init(|| text_fallback_font_spec().and_then(|spec| CString::new(spec).ok()))
            .as_ref()
            .map_or(std::ptr::null(), |spec| spec.as_ptr())
    })
}

/// # Safety
/// `tex` must point to `len` readable bytes (it may be NULL when `len` is 0).
#[no_mangle]
pub unsafe extern "C" fn ratex_bridge_parse(
    tex: *const c_char,
    len: usize,
    display: c_int,
    font_px: f64,
) -> *mut Formula {
    guarded(std::ptr::null_mut(), || {
        if tex.is_null() && len > 0 {
            set_last_error("tex is NULL");
            return std::ptr::null_mut();
        }
        // Before touching the bytes at all.
        if len > MAX_TEX_BYTES {
            set_last_error(&format!("formula is longer than {MAX_TEX_BYTES} bytes"));
            return std::ptr::null_mut();
        }
        let bytes = if len == 0 {
            &[][..]
        } else {
            std::slice::from_raw_parts(tex.cast::<u8>(), len)
        };
        let Ok(source) = std::str::from_utf8(bytes) else {
            set_last_error("tex is not valid UTF-8");
            return std::ptr::null_mut();
        };
        match parse_formula(source, display != 0, font_px) {
            Ok(formula) => Box::into_raw(Box::new(formula)),
            Err(message) => {
                set_last_error(&message);
                std::ptr::null_mut()
            }
        }
    })
}

/// # Safety
/// `formula` must be NULL or a live pointer from `ratex_bridge_parse`; the
/// out pointers may each be NULL.
#[no_mangle]
pub unsafe extern "C" fn ratex_bridge_metrics(
    formula: *const Formula,
    width: *mut f64,
    height: *mut f64,
    depth: *mut f64,
) -> c_int {
    guarded(-1, || {
        let Some(formula) = formula.as_ref() else {
            set_last_error("formula is NULL");
            return -1;
        };
        if let Some(out) = width.as_mut() {
            *out = formula.width;
        }
        if let Some(out) = height.as_mut() {
            *out = formula.height;
        }
        if let Some(out) = depth.as_mut() {
            *out = formula.depth;
        }
        0
    })
}

/// # Safety
/// `formula` must be a live pointer from `ratex_bridge_parse` and `cr` a
/// valid `cairo_t *` for the duration of the call.
#[no_mangle]
pub unsafe extern "C" fn ratex_bridge_draw(
    formula: *mut Formula,
    cr: *mut c_void,
    red: f64,
    green: f64,
    blue: f64,
    alpha: f64,
) -> c_int {
    guarded(-1, || {
        let Some(formula) = formula.as_ref() else {
            set_last_error("formula is NULL");
            return -1;
        };
        if cr.is_null() {
            set_last_error("cairo context is NULL");
            return -1;
        }
        let unit = |value: f64| if value.is_finite() { value.clamp(0.0, 1.0) as f32 } else { 0.0 };
        let color = Color::new(unit(red), unit(green), unit(blue), unit(alpha));

        // from_raw_none takes its own reference and drops it again, so the
        // caller keeps ownership of the context.
        let context = cairo::Context::from_raw_none(cr.cast::<cairo::ffi::cairo_t>());
        if let Err(error) = context.save() {
            set_last_error(&format!("cairo: {error}"));
            return -1;
        }
        let options = CairoOptions { font_size: formula.font_px, padding: 0.0, font_dir: None };
        let result = formula.with_display_list(color, |list| render_to_cairo(&context, list, &options));
        let _ = context.restore();
        match result {
            Ok(()) => 0,
            Err(error) => {
                set_last_error(&error.to_string());
                -1
            }
        }
    })
}

/// # Safety
/// `formula` must be NULL or a pointer from `ratex_bridge_parse` that has not
/// been freed yet.
#[no_mangle]
pub unsafe extern "C" fn ratex_bridge_free(formula: *mut Formula) {
    guarded((), || {
        if !formula.is_null() {
            drop(Box::from_raw(formula));
        }
    });
}

/// Estimated bytes all live formulas keep.
#[no_mangle]
pub extern "C" fn ratex_bridge_live_bytes() -> usize {
    LIVE_BYTES.load(Ordering::Relaxed)
}

/// Sets the limit on `ratex_bridge_live_bytes()` and returns the old one.
#[no_mangle]
pub extern "C" fn ratex_bridge_set_live_bytes_limit(limit: usize) -> usize {
    LIVE_BYTES_LIMIT.swap(limit, Ordering::Relaxed)
}

/// Whether the last error on the calling thread was the memory limit, which
/// the same formula may pass once other formulas are freed.
#[no_mangle]
pub extern "C" fn ratex_bridge_last_error_is_transient() -> c_int {
    catch_unwind(|| c_int::from(LAST_ERROR_IS_TRANSIENT.try_with(std::cell::Cell::get).unwrap_or(false))).unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn ratex_bridge_last_error() -> *const c_char {
    catch_unwind(|| {
        LAST_ERROR
            .try_with(|cell| match cell.try_borrow() {
                Ok(slot) => slot.as_ref().map_or(std::ptr::null(), |message| message.as_ptr()),
                Err(_) => std::ptr::null(),
            })
            .unwrap_or(std::ptr::null())
    })
    .unwrap_or(std::ptr::null())
}
