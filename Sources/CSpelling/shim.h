#ifndef SWIFTYNOTES_CSPELLING_SHIM_H
#define SWIFTYNOTES_CSPELLING_SHIM_H

#include <libspelling.h>

// libspelling renamed `SpellingLanguageInfo` → `SpellingLanguage` and the
// matching `spelling_language_info_get_*` accessors → `spelling_language_get_*`
// somewhere around 0.4.0. Ubuntu 24.04 LTS (Noble) ships 0.2.0, Ubuntu 26.04
// (Resolute) ships 0.4.9. Provide a single facade so the rest of the shim
// doesn't care which side of the rename it's on.
#if (SPELLING_MAJOR_VERSION > 0) || (SPELLING_MINOR_VERSION >= 4)
typedef SpellingLanguage SwiftyNotesSpellingLanguageItem;
#define swifty_notes_spelling_lang_get_code(item) spelling_language_get_code(item)
#define swifty_notes_spelling_lang_get_name(item) spelling_language_get_name(item)
#else
typedef SpellingLanguageInfo SwiftyNotesSpellingLanguageItem;
#define swifty_notes_spelling_lang_get_code(item) spelling_language_info_get_code(item)
#define swifty_notes_spelling_lang_get_name(item) spelling_language_info_get_name(item)
#endif

// Both `swift-adwaita`'s CAdwaita module and our CSpelling module pull
// in `<gtk/gtk.h>` and `<gtksourceview/gtksource.h>`, so Swift treats
// the resulting `GtkWidget` / `GtkSourceBuffer` types as two distinct
// types — pointer values from the `swift-adwaita` widget hierarchy
// can't be passed straight into libspelling C functions. The
// G_DECLARE_FINAL_TYPE-generated `SpellingTextBufferAdapter` struct
// also doesn't import into Swift cleanly. These thin shims take and
// return opaque (`gpointer` / `void *`) pointers and do the casts on
// the C side so the Swift wrapper can stay in `OpaquePointer` land.

static inline gpointer
swifty_notes_spelling_attach(gpointer source_buffer,
                             gpointer source_view) {
    GtkSourceBuffer *buffer = (GtkSourceBuffer *)source_buffer;
    SpellingChecker *checker = spelling_checker_get_default();
    if (checker == NULL) {
        return NULL;
    }
    SpellingTextBufferAdapter *adapter =
        spelling_text_buffer_adapter_new(buffer, checker);
    if (adapter == NULL) {
        return NULL;
    }
    spelling_text_buffer_adapter_set_enabled(adapter, TRUE);
    GtkWidget *widget = (GtkWidget *)source_view;
    GMenuModel *menu = spelling_text_buffer_adapter_get_menu_model(adapter);
    if (menu != NULL) {
        gtk_text_view_set_extra_menu(GTK_TEXT_VIEW(widget), menu);
    }
    gtk_widget_insert_action_group(widget,
                                   "spelling",
                                   G_ACTION_GROUP(adapter));
    return adapter;
}

static inline gboolean
swifty_notes_spelling_get_enabled(gpointer adapter) {
    return spelling_text_buffer_adapter_get_enabled(
        (SpellingTextBufferAdapter *)adapter);
}

static inline void
swifty_notes_spelling_set_enabled(gpointer adapter, gboolean enabled) {
    spelling_text_buffer_adapter_set_enabled(
        (SpellingTextBufferAdapter *)adapter, enabled);
}

static inline const char *
swifty_notes_spelling_get_language(gpointer adapter) {
    return spelling_text_buffer_adapter_get_language(
        (SpellingTextBufferAdapter *)adapter);
}

static inline void
swifty_notes_spelling_set_language(gpointer adapter, const char *language) {
    spelling_text_buffer_adapter_set_language(
        (SpellingTextBufferAdapter *)adapter, language);
}

// Forces a full rescan of the buffer. Without this, replacing the
// buffer's text wholesale (which is what happens when the user
// switches notes) keeps stale misspelling tags around and new content
// never gets checked.
static inline void
swifty_notes_spelling_invalidate_all(gpointer adapter) {
    spelling_text_buffer_adapter_invalidate_all(
        (SpellingTextBufferAdapter *)adapter);
}

// Creates the well-known "no spell check" GtkTextTag inside the given
// GtkSourceBuffer (passed in opaquely so we don't fight Swift's
// duplicate-`GtkSourceBuffer` situation). The tag's name is the magic
// string libspelling looks for — anything tagged with it gets skipped
// by the spell-check adapter. Returns the tag as an opaque pointer.
static inline gpointer
swifty_notes_spelling_create_no_spell_tag(gpointer source_buffer) {
    GtkTextBuffer *buffer = GTK_TEXT_BUFFER(source_buffer);
    return gtk_text_buffer_create_tag(
        buffer,
        "gtksourceview:context-classes:no-spell-check",
        NULL);
}

static inline void
swifty_notes_spelling_apply_no_spell_tag(gpointer source_buffer,
                                         gpointer tag,
                                         int start_offset,
                                         int end_offset) {
    GtkTextBuffer *buffer = GTK_TEXT_BUFFER(source_buffer);
    GtkTextIter start_iter;
    GtkTextIter end_iter;
    gtk_text_buffer_get_iter_at_offset(buffer, &start_iter, start_offset);
    gtk_text_buffer_get_iter_at_offset(buffer, &end_iter, end_offset);
    gtk_text_buffer_apply_tag(buffer, (GtkTextTag *)tag, &start_iter, &end_iter);
}

static inline void
swifty_notes_spelling_remove_no_spell_tag(gpointer source_buffer,
                                          gpointer tag,
                                          int start_offset,
                                          int end_offset) {
    GtkTextBuffer *buffer = GTK_TEXT_BUFFER(source_buffer);
    GtkTextIter start_iter;
    GtkTextIter end_iter;
    gtk_text_buffer_get_iter_at_offset(buffer, &start_iter, start_offset);
    gtk_text_buffer_get_iter_at_offset(buffer, &end_iter, end_offset);
    gtk_text_buffer_remove_tag(buffer, (GtkTextTag *)tag, &start_iter, &end_iter);
}

// Iterates over every language exposed by the default checker's
// provider, calling `callback(code, name, user_data)` for each.
// `code` is an IETF tag like `en_US`; `name` is a localized display
// name like "English (United States)". The strings are owned by
// libspelling and stay valid for the duration of the call.
typedef void (*SwiftyNotesSpellingLanguageCallback)(const char *code,
                                                    const char *name,
                                                    void *user_data);

static inline void
swifty_notes_spelling_for_each_language(SwiftyNotesSpellingLanguageCallback callback,
                                        void *user_data) {
    if (callback == NULL) {
        return;
    }
    SpellingChecker *checker = spelling_checker_get_default();
    if (checker == NULL) {
        return;
    }
    SpellingProvider *provider = spelling_checker_get_provider(checker);
    if (provider == NULL) {
        return;
    }
    GListModel *model = spelling_provider_list_languages(provider);
    if (model == NULL) {
        return;
    }
    guint count = g_list_model_get_n_items(model);
    for (guint i = 0; i < count; i++) {
        SwiftyNotesSpellingLanguageItem *language = g_list_model_get_item(model, i);
        if (language != NULL) {
            callback(swifty_notes_spelling_lang_get_code(language),
                     swifty_notes_spelling_lang_get_name(language),
                     user_data);
            g_object_unref(language);
        }
    }
    g_object_unref(model);
}

// ---------------------------------------------------------------------------
// Outline-fold helpers — same opaque-pointer pattern as the no-spell-tag
// shims above. `invisible` is a GtkTextTag property exposed only through
// `g_object_set`; wrapping the variadic call in C keeps the Swift caller
// out of GValue/property-name juggling. The tag is named so we can look
// it up later instead of caching the pointer ourselves.
static inline gpointer
swifty_notes_outline_create_fold_tag(gpointer source_buffer) {
    GtkTextBuffer *buffer = GTK_TEXT_BUFFER(source_buffer);
    GtkTextTagTable *table = gtk_text_buffer_get_tag_table(buffer);
    GtkTextTag *existing = gtk_text_tag_table_lookup(table, "swifty-notes-outline-fold");
    if (existing != NULL) {
        return existing;
    }
    return gtk_text_buffer_create_tag(buffer,
                                      "swifty-notes-outline-fold",
                                      "invisible", TRUE,
                                      NULL);
}

static inline void
swifty_notes_outline_clear_fold(gpointer source_buffer, gpointer tag) {
    GtkTextBuffer *buffer = GTK_TEXT_BUFFER(source_buffer);
    GtkTextIter start_iter;
    GtkTextIter end_iter;
    gtk_text_buffer_get_bounds(buffer, &start_iter, &end_iter);
    gtk_text_buffer_remove_tag(buffer, (GtkTextTag *)tag, &start_iter, &end_iter);
}

static inline void
swifty_notes_outline_apply_fold(gpointer source_buffer, gpointer tag,
                                int heading_line, int boundary_line) {
    GtkTextBuffer *buffer = GTK_TEXT_BUFFER(source_buffer);
    GtkTextIter start_iter;
    GtkTextIter end_iter;
    gtk_text_buffer_get_iter_at_line(buffer, &start_iter, heading_line);
    // Move start to end of the heading line so the heading itself
    // stays visible; the fold hides body + trailing newlines.
    gtk_text_iter_forward_to_line_end(&start_iter);
    gtk_text_buffer_get_iter_at_line(buffer, &end_iter, boundary_line);
    if (gtk_text_iter_compare(&start_iter, &end_iter) < 0) {
        gtk_text_buffer_apply_tag(buffer, (GtkTextTag *)tag, &start_iter, &end_iter);
    }
}

// ---------------------------------------------------------------------------
// Find-bar highlight helpers — same g_object_set wrapping as the
// outline-fold tag above. Two tags so the active match (the one
// `step` just landed on) is distinguishable from the rest:
//
//   - `swifty-notes-search-match`        — yellow background, dim text;
//   - `swifty-notes-search-match-active` — saturated background, dark text.
//
// Both tags are persistent on the buffer's tag table once created;
// `gtk_text_buffer_remove_tag` is the way to clear highlights, not
// destroying the tags themselves.
static inline gpointer
swifty_notes_search_create_match_tag(gpointer source_buffer) {
    GtkTextBuffer *buffer = GTK_TEXT_BUFFER(source_buffer);
    GtkTextTagTable *table = gtk_text_buffer_get_tag_table(buffer);
    GtkTextTag *existing = gtk_text_tag_table_lookup(table, "swifty-notes-search-match");
    if (existing != NULL) {
        return existing;
    }
    return gtk_text_buffer_create_tag(buffer,
                                      "swifty-notes-search-match",
                                      "background", "#fff59d",
                                      "foreground", "#1e1e1e",
                                      NULL);
}

static inline gpointer
swifty_notes_search_create_active_tag(gpointer source_buffer) {
    GtkTextBuffer *buffer = GTK_TEXT_BUFFER(source_buffer);
    GtkTextTagTable *table = gtk_text_buffer_get_tag_table(buffer);
    GtkTextTag *existing = gtk_text_tag_table_lookup(table, "swifty-notes-search-match-active");
    if (existing != NULL) {
        return existing;
    }
    return gtk_text_buffer_create_tag(buffer,
                                      "swifty-notes-search-match-active",
                                      "background", "#f9a825",
                                      "foreground", "#1e1e1e",
                                      "weight", PANGO_WEIGHT_BOLD,
                                      NULL);
}

static inline void
swifty_notes_search_clear_tags(gpointer source_buffer, gpointer match_tag, gpointer active_tag) {
    GtkTextBuffer *buffer = GTK_TEXT_BUFFER(source_buffer);
    GtkTextIter start_iter;
    GtkTextIter end_iter;
    gtk_text_buffer_get_bounds(buffer, &start_iter, &end_iter);
    if (match_tag != NULL) {
        gtk_text_buffer_remove_tag(buffer, (GtkTextTag *)match_tag, &start_iter, &end_iter);
    }
    if (active_tag != NULL) {
        gtk_text_buffer_remove_tag(buffer, (GtkTextTag *)active_tag, &start_iter, &end_iter);
    }
}

static inline void
swifty_notes_search_apply_tag(gpointer source_buffer, gpointer tag,
                              int start_offset, int end_offset) {
    GtkTextBuffer *buffer = GTK_TEXT_BUFFER(source_buffer);
    GtkTextIter start_iter;
    GtkTextIter end_iter;
    gtk_text_buffer_get_iter_at_offset(buffer, &start_iter, start_offset);
    gtk_text_buffer_get_iter_at_offset(buffer, &end_iter, end_offset);
    if (gtk_text_iter_compare(&start_iter, &end_iter) < 0) {
        gtk_text_buffer_apply_tag(buffer, (GtkTextTag *)tag, &start_iter, &end_iter);
    }
}

// ---------------------------------------------------------------------------
// The gettext helpers that used to live here (textdomain, bindtextdomain,
// bind_textdomain_codeset, the _nl_msg_cat_cntr bump and the LC_MESSAGES
// wrappers) moved into swift-adwaita, which now exposes them as
// configureLocalization / setLanguage / applyTextDirection. <libintl.h> is not
// in the Glibc module, so every app was writing this shim; it belongs in the
// library.

#include <libgen.h>

#endif /* SWIFTYNOTES_CSPELLING_SHIM_H */
