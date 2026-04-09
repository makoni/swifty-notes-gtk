import Foundation

enum SwiftyNotesOverviewSeed {
    static let content = """
    # About Swifty Notes

    *Native markdown notes for Linux, built with Swift, GTK 4, and libadwaita.*

    Swifty Notes is a desktop-first notes app that keeps every note as plain Markdown on disk while pairing it with a polished native interface.

    ## Why it stands out

    - Native editor, preview, and window chrome
    - Three focused working modes: `Editor`, `Split`, and `Preview`
    - Formatting toolbar for headings, emphasis, links, lists, quotes, and task items
    - Autosave, search, sorting, and workspace restore
    - CLI access to the same notes directory for scripts and AI agents

    ## Storage Model

    | File | Purpose |
    | --- | --- |
    | `note.md` | The markdown content |
    | `meta.json` | Stable ID and timestamps |
    | `assets/` | Imported images for the note |

    ## Great for

    1. Project docs and meeting notes
    2. Personal knowledge bases
    3. Plain-file workflows synced with Nextcloud, Syncthing, or Git
    4. Automated note generation from terminal tools

    ## Typical Flow

    1. Capture text in the editor
    2. Refine formatting with the toolbar
    3. Review the native preview
    4. Script batch changes through `swiftynotes cli`

    > Everything stays readable as plain files, so you keep ownership of your notes.
    """
}
