import Adwaita

// AdwToast reads its title as Pango markup by default, so a note's title or
// an error message holding `&` or `<` breaks it (GTK logs the text and the
// toast shows nothing) and a crafted title could put a link in it. The app's
// toasts show their text as written.

extension Toast {
    /// A toast whose title is shown as written, not read as markup.
    static func plain(_ title: String) -> Toast {
        let toast = Toast(title: title)
        toast.useMarkup = false
        return toast
    }
}

extension ToastOverlay {
    /// Shows `title` as written (see ``Toast/plain(_:)``).
    func showPlainToast(_ title: String) {
        addToast(.plain(title))
    }

    /// Shows `title` as written, with a button that runs `handler`.
    func showPlainToast(_ title: String, button: String, handler: @escaping @MainActor () -> Void) {
        let toast = Toast.plain(title)
        toast.buttonLabel = button
        toast.onButtonClicked(handler)
        addToast(toast)
    }
}
