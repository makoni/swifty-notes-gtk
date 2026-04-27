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

#endif /* SWIFTYNOTES_CSPELLING_SHIM_H */
