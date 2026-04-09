import Foundation

enum SwiftyNotesCLISeed {
    static let content = """
    # Using Swifty Notes CLI

    *The desktop app and the CLI work with the same file-backed markdown notes.*

    The CLI is handy when you want to script note creation, inspect content from a terminal, or let another tool update notes without touching the GUI.

    ## Core Commands

    ```bash
    swiftynotes cli list
    swiftynotes cli get <note-id>
    swiftynotes cli get <note-id> --raw
    swiftynotes cli create --content '# Title\n\nBody'
    swiftynotes cli update <note-id> --stdin
    ```

    ## Typical Workflow

    1. Run `swiftynotes cli list` to find the note ID you want.
    2. Use `get --raw` when you need the markdown exactly as stored.
    3. Pipe fresh markdown into `update --stdin` to replace a note in one step.
    4. Use `create --content` for quick capture from scripts and shell aliases.

    ## Helpful Tips

    - Pass `--notes-dir /path/to/notes` to target a custom notes folder.
    - IDs are lowercase UUID strings and stay stable across GUI and CLI usage.
    - `update` replaces the full markdown body, so generate the final document before sending it.

    ## Example

    ```bash
    swiftynotes cli list | jq .
    printf '# Release checklist\n\n- [x] Draft screenshots\n- [ ] Publish release notes\n' \\
      | swiftynotes cli update 00000000-0000-0000-0000-000000000000 --stdin
    ```

    > The CLI is designed for shell scripts, automation, and AI agents that need to work with the same notes as the desktop app.
    """
}
