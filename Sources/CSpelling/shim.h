#ifndef SWIFTYNOTES_CSPELLING_SHIM_H
#define SWIFTYNOTES_CSPELLING_SHIM_H

#include <libspelling.h>

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
        SpellingLanguage *language = g_list_model_get_item(model, i);
        if (language != NULL) {
            callback(spelling_language_get_code(language),
                     spelling_language_get_name(language),
                     user_data);
            g_object_unref(language);
        }
    }
    g_object_unref(model);
}

#endif /* SWIFTYNOTES_CSPELLING_SHIM_H */
