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
use std::sync::{Arc, Mutex, OnceLock};

use ab_glyph::{Font, FontRef};
use ratex_cairo::{render_to_cairo, CairoOptions};
use ratex_layout::{
    layout_with_fallback_metrics, to_display_list, validate_layout, FallbackGlyphMetrics,
    LayoutOptions,
};
use ratex_parser::{parse, ParseNode};
use ratex_types::color::Color;
use ratex_types::math_style::MathStyle;
use ratex_types::DisplayList;

/// Longest TeX source the bridge accepts. Some constructs (`\ce` in
/// particular) parse in quadratic time, so the app caps formulas well below
/// this; the bridge only guards against pathological input.
const MAX_TEX_BYTES: usize = 8 * 1024;

/// Largest box, in pixels, the bridge hands out. Anything bigger is a
/// deliberately absurd formula (`\hspace{1e9pt}`) that would overflow Pango
/// units or cairo surfaces downstream.
const MAX_BOX_PX: f64 = 16_384.0;

// ---------------------------------------------------------------------------
// Thread-local last error
// ---------------------------------------------------------------------------

thread_local! {
    static LAST_ERROR: RefCell<Option<CString>> = const { RefCell::new(None) };
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

/// A parsed formula. The layout is redone per default colour (the theme can
/// change between draws) and the last one is cached.
pub struct Formula {
    nodes: Vec<ParseNode>,
    style: MathStyle,
    fallback_metrics: Arc<HashMap<char, FallbackGlyphMetrics>>,
    font_px: f64,
    width: f64,
    height: f64,
    depth: f64,
    cached: Mutex<Option<(Color, DisplayList)>>,
}

impl Formula {
    fn layout(&self, color: Color) -> Result<DisplayList, String> {
        let options = LayoutOptions::default().with_style(self.style).with_color(color);
        let tree = layout_with_fallback_metrics(&self.nodes, &options, Arc::clone(&self.fallback_metrics));
        validate_layout(&tree).map_err(|error| format!("layout rejected: {error}"))?;
        Ok(to_display_list(&tree))
    }

    fn display_list(&self, color: Color) -> Result<DisplayList, String> {
        let mut cached = self.cached.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some((cached_color, list)) = cached.as_ref() {
            if *cached_color == color {
                return Ok(list.clone());
            }
        }
        let list = self.layout(color)?;
        *cached = Some((color, list.clone()));
        Ok(list)
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
    let nodes = parse(tex).map_err(|error| format!("parse error: {error}"))?;
    let mut formula = Formula {
        nodes,
        style: if display { MathStyle::Display } else { MathStyle::Text },
        fallback_metrics: Arc::new(fallback_metrics(tex)),
        font_px,
        width: 0.0,
        height: 0.0,
        depth: 0.0,
        cached: Mutex::new(None),
    };
    let list = formula.layout(Color::BLACK)?;
    let width = list.width * font_px;
    let height = (list.height + list.depth) * font_px;
    let depth = list.depth * font_px;
    let sane = |value: f64| value.is_finite() && (0.0..=MAX_BOX_PX).contains(&value);
    if !sane(width) || !sane(height) || !sane(depth) || depth > height {
        return Err(format!("formula box {width}×{height} px is out of range"));
    }
    formula.width = width;
    formula.height = height;
    formula.depth = depth;
    *formula.cached.get_mut().unwrap_or_else(|poisoned| poisoned.into_inner()) = Some((Color::BLACK, list));
    Ok(formula)
}

// ---------------------------------------------------------------------------
// Text fallback font
// ---------------------------------------------------------------------------

// fontconfig is already in the process (Pango and cairo use it); these are
// the few calls needed to ask it for a font.
#[link(name = "fontconfig")]
extern "C" {
    fn FcNameParse(name: *const u8) -> *mut c_void;
    fn FcConfigSubstitute(config: *mut c_void, pattern: *mut c_void, kind: c_int) -> c_int;
    fn FcDefaultSubstitute(pattern: *mut c_void);
    fn FcFontMatch(config: *mut c_void, pattern: *mut c_void, result: *mut c_int) -> *mut c_void;
    fn FcPatternGetString(pattern: *const c_void, object: *const c_char, n: c_int, value: *mut *mut u8) -> c_int;
    fn FcPatternGetInteger(pattern: *const c_void, object: *const c_char, n: c_int, value: *mut c_int) -> c_int;
    fn FcPatternDestroy(pattern: *mut c_void);
}

const FC_MATCH_PATTERN: c_int = 0;
const FC_RESULT_MATCH: c_int = 0;

/// The serif system font fontconfig picks for Russian text, as a RaTeX font
/// spec (`path` or `path#index`), if it also has Greek. RaTeX draws text the
/// KaTeX fonts lack (`\text{Площадь}`) with one system font; left to itself
/// it looks for Noto Sans CJK at a fixed path (absent in Flatpak runtimes)
/// and then guesses by locale. A serif with Cyrillic and Greek matches
/// KaTeX's own text font far better.
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
        let has_file = FcPatternGetString(matched, c"file".as_ptr(), 0, &mut file) == FC_RESULT_MATCH && !file.is_null();
        let path = has_file.then(|| std::ffi::CStr::from_ptr(file.cast()).to_string_lossy().into_owned());
        if FcPatternGetInteger(matched, c"index".as_ptr(), 0, &mut index) != FC_RESULT_MATCH {
            index = 0;
        }
        FcPatternDestroy(matched);
        let path = path?;
        let data = std::fs::read(&path).ok()?;
        let font = FontRef::try_from_slice_and_index(&data, u32::try_from(index).ok()?).ok()?;
        if font.glyph_id('ж').0 == 0 || font.glyph_id('α').0 == 0 {
            return None;
        }
        Some(if index == 0 { path } else { format!("{path}#{index}") })
    }
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
        let list = match formula.display_list(color) {
            Ok(list) => list,
            Err(message) => {
                set_last_error(&message);
                return -1;
            }
        };
        // from_raw_none takes its own reference and drops it again, so the
        // caller keeps ownership of the context.
        let context = cairo::Context::from_raw_none(cr.cast::<cairo::ffi::cairo_t>());
        if let Err(error) = context.save() {
            set_last_error(&format!("cairo: {error}"));
            return -1;
        }
        let options = CairoOptions { font_size: formula.font_px, padding: 0.0, font_dir: None };
        let result = render_to_cairo(&context, &list, &options);
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
