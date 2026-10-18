/*
 * ratex_bridge.h — plain-C interface to the RaTeX math engine.
 *
 * Built from Sources/RaTeXBridge (Rust) by scripts/build-ratex-bridge.sh.
 * No function lets a Rust panic escape: a failure comes back as NULL or -1
 * and is described by ratex_bridge_last_error().
 */

#ifndef RATEX_BRIDGE_H
#define RATEX_BRIDGE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* A parsed, laid-out formula: its drawing, recoloured in place (under a
 * lock) when the default colour changes, so it may be used from any
 * thread. */
typedef struct ratex_bridge_formula ratex_bridge_formula;

/*
 * Parses `tex` (`len` bytes of UTF-8, not NUL-terminated) and lays it out at
 * `font_px` pixels per em. `display` != 0 selects display style (fractions
 * and limits set at full size), 0 the inline text style.
 *
 * Returns NULL when the TeX does not parse, is longer than the bridge's input
 * limit, lays out to a box that is not finite or is unreasonably large, would
 * keep too much memory, or when the live formulas together already keep
 * their limit (see ratex_bridge_set_live_bytes_limit).
 * Characters the KaTeX fonts lack (Cyrillic, CJK, …) are measured with the
 * same system font the renderer draws them with.
 */
ratex_bridge_formula *ratex_bridge_parse(const char *tex, size_t len, int display, double font_px);

/*
 * Box metrics in pixels: `width`, `height` (the whole box, top to bottom) and
 * `depth` (the part below the baseline). The baseline therefore sits
 * `height - depth` below the top. Returns 0, or -1 for a NULL formula.
 */
int ratex_bridge_metrics(const ratex_bridge_formula *formula, double *width, double *height, double *depth);

/*
 * Draws the formula with its box's top-left corner at the origin of `cr`
 * (a `cairo_t *`). Parts without an explicit \color use the given default
 * colour (components 0…1); explicit colours, black included, are kept.
 * The cairo state is saved and restored, but cairo's save/restore does not
 * cover the current path or point: read the current point before calling.
 * Returns 0 on success, -1 on failure.
 */
int ratex_bridge_draw(ratex_bridge_formula *formula, void *cr, double red, double green, double blue, double alpha);

/* Frees a formula. NULL is ignored. */
void ratex_bridge_free(ratex_bridge_formula *formula);

/* The most bytes one formula may keep; larger ones are refused. */
size_t ratex_bridge_max_formula_bytes(void);

/* Diagnostics: 1 when emoji are drawn as colour images (an emoji font the
 * engine can read was found), else 0. */
int ratex_bridge_draws_emoji_images(void);

/* Diagnostics: estimated bytes all live (not yet freed) formulas keep. */
size_t ratex_bridge_live_bytes(void);

/*
 * Sets how many estimated bytes all live formulas may keep together (192 MiB
 * by default); past it ratex_bridge_parse refuses new formulas until some
 * are freed. Returns the previous limit.
 */
size_t ratex_bridge_set_live_bytes_limit(size_t limit);

/*
 * Whether the last error on the calling thread was the memory limit above:
 * the same formula may parse once others are freed. 1 or 0.
 */
int ratex_bridge_last_error_is_transient(void);

/*
 * The last error on the calling thread, or NULL. Valid until the next bridge
 * call on the same thread.
 */
const char *ratex_bridge_last_error(void);

/*
 * The serif system font (from fontconfig, with Cyrillic and Greek) RaTeX
 * should draw text with that the KaTeX fonts lack, as a value for the
 * RATEX_UNICODE_FONT environment variable, or NULL if there is none (always
 * on macOS, where RaTeX's own discovery finds Arial Unicode). RaTeX
 * reads that variable once, so set it before the first formula — and, as
 * changing the environment is not thread-safe, before starting threads.
 */
const char *ratex_bridge_text_fallback_font(void);

#ifdef __cplusplus
}
#endif

#endif
