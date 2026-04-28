import Foundation

struct NotesCLIExecutionResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

private enum CLIHelpTopic {
    case general
    case list
    case get
    case create
    case update
    case move
    case folders
    case foldersCreate
    case foldersRm
    case foldersRename
    case foldersMove
}

enum NotesCLI {
    static func runIfRequested(
        arguments: [String],
        stdin: Data? = nil,
    ) -> NotesCLIExecutionResult? {
        // Drop a leading "--" — some SwiftPM versions forward it to the
        // child process when invoked as `swift run swiftynotes -- cli ...`.
        // Older swift used to consume it, newer ones pass it through, and
        // we want both forms to dispatch to the CLI.
        var trimmed = arguments
        if trimmed.first == "--" {
            trimmed.removeFirst()
        }
        guard trimmed.first == "cli" else { return nil }
        return run(arguments: Array(trimmed.dropFirst()), stdin: stdin)
    }

    private static func run(
        arguments: [String],
        stdin: Data?,
    ) -> NotesCLIExecutionResult {
        do {
            let parsed = try ParsedInvocation(arguments: arguments, stdin: stdin)
            let repository = NotesRepository(
                notesDirectory: parsed.notesDirectory ?? CLINotesDirectoryResolver.resolve(),
            )

            let output: String
            switch parsed.command {
            case let .help(topic):
                output = help(for: topic)
            case let .list(folderScope):
                let notes = try repository.loadNotes()
                let filtered = filterNotesByFolder(notes, scope: folderScope)
                output = try encodeJSON(filtered.map(CLINoteSummary.init))
            case let .get(noteID, raw):
                let note = try loadNote(id: noteID, repository: repository)
                output = raw ? note.content : try encodeJSON(CLINoteDocument(note: note))
            case let .create(content, folderPath):
                let normalizedFolder = NotesRepository.trimmedFolderPath(folderPath)
                if !normalizedFolder.isEmpty {
                    try ensureFolderExists(normalizedFolder, repository: repository)
                }
                let note = try repository.createNote(
                    initialContent: content,
                    in: normalizedFolder,
                )
                output = try encodeJSON(CLINoteDocument(note: note))
            case let .update(noteID, content):
                var note = try loadNote(id: noteID, repository: repository)
                note.content = content
                let saved = try repository.save(note: note)
                output = try encodeJSON(CLINoteDocument(note: saved))
            case .folders:
                let folders = try repository.listFolders()
                output = try encodeJSON(folders)
            case let .move(noteID, folderPath):
                let normalizedFolder = NotesRepository.trimmedFolderPath(folderPath)
                if !normalizedFolder.isEmpty {
                    try ensureFolderExists(normalizedFolder, repository: repository)
                }
                let note = try loadNote(id: noteID, repository: repository)
                let moved = try repository.move(note: note, to: normalizedFolder)
                output = try encodeJSON(CLINoteDocument(note: moved))
            case let .foldersCreate(path):
                try repository.createFolder(at: path)
                output = try encodeJSON(CLIFolderOperation(action: "created", path: NotesRepository.trimmedFolderPath(path), to: nil))
            case let .foldersRm(path, yes):
                let trimmed = NotesRepository.trimmedFolderPath(path)
                guard !trimmed.isEmpty else {
                    throw NotesCLIError.usage("`folders rm` cannot delete the root.")
                }
                try assertFolderRemovable(trimmed, repository: repository, yes: yes)
                try repository.deleteFolderRecursively(at: trimmed)
                output = try encodeJSON(CLIFolderOperation(action: "deleted", path: trimmed, to: nil))
            case let .foldersRename(path, newName):
                let trimmed = NotesRepository.trimmedFolderPath(path)
                try repository.renameFolder(at: trimmed, to: newName)
                let parent = NotesRepository.parentFolderPath(of: trimmed)
                let renamedPath = parent.isEmpty ? newName : "\(parent)/\(newName)"
                output = try encodeJSON(CLIFolderOperation(action: "renamed", path: trimmed, to: renamedPath))
            case let .foldersMove(path, newParent):
                let trimmedPath = NotesRepository.trimmedFolderPath(path)
                let trimmedParent = NotesRepository.trimmedFolderPath(newParent)
                try repository.moveFolder(at: trimmedPath, to: trimmedParent)
                let lastComponent = (trimmedPath as NSString).lastPathComponent
                let movedPath = trimmedParent.isEmpty ? lastComponent : "\(trimmedParent)/\(lastComponent)"
                output = try encodeJSON(CLIFolderOperation(action: "moved", path: trimmedPath, to: movedPath))
            }

            return .init(
                exitCode: 0,
                stdout: output.hasSuffix("\n") ? output : "\(output)\n",
                stderr: "",
            )
        } catch let error as NotesCLIError {
            return .init(exitCode: error.exitCode, stdout: "", stderr: "\(error.message)\n")
        } catch {
            return .init(exitCode: 1, stdout: "", stderr: "\(error.localizedDescription)\n")
        }
    }

    private static func loadNote(id: UUID, repository: NotesRepository) throws -> Note {
        let notes = try repository.loadNotes()
        guard let note = notes.first(where: { $0.id == id }) else {
            throw NotesCLIError.notFound("No note found for ID \(id.uuidString.lowercased())")
        }
        return note
    }

    private static func filterNotesByFolder(_ notes: [Note], scope: String) -> [Note] {
        let normalized = NotesRepository.trimmedFolderPath(scope)
        guard !normalized.isEmpty else { return notes }
        return notes.filter { note in
            note.folderPath == normalized
                || note.folderPath.hasPrefix("\(normalized)/")
        }
    }

    private static func ensureFolderExists(_ folderPath: String, repository: NotesRepository) throws {
        let existing = try repository.listFolders()
        if existing.contains(folderPath) { return }
        do {
            try repository.createFolder(at: folderPath)
        } catch NotesRepositoryFolderError.alreadyExists {
            // Concurrent creator beat us to it — that's fine, the folder is here now.
        }
    }

    /// Refuses to recursively delete a folder that still contains notes or
    /// subfolders unless the caller passed `--yes`. Mirrors apt-style
    /// "interactive by default, scriptable with -y" semantics.
    private static func assertFolderRemovable(
        _ folderPath: String,
        repository: NotesRepository,
        yes: Bool,
    ) throws {
        let nestedNotes = try repository.loadNotes().count(where: { note in
            note.folderPath == folderPath || note.folderPath.hasPrefix("\(folderPath)/")
        })
        let nestedFolders = try repository.listFolders().count(where: { entry in
            entry != folderPath && entry.hasPrefix("\(folderPath)/")
        })
        guard nestedNotes > 0 || nestedFolders > 0 else { return }
        if yes { return }
        var parts: [String] = []
        if nestedNotes > 0 { parts.append(nestedNotes == 1 ? "1 note" : "\(nestedNotes) notes") }
        if nestedFolders > 0 { parts.append(nestedFolders == 1 ? "1 subfolder" : "\(nestedFolders) subfolders") }
        throw NotesCLIError.usage(
            "\"\(folderPath)\" contains \(parts.joined(separator: " and ")). Pass --yes to delete it recursively.",
        )
    }

    private static func encodeJSON(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw NotesCLIError.runtime("Could not encode CLI output")
        }
        return string
    }

    fileprivate static func help(for topic: CLIHelpTopic) -> String {
        switch topic {
        case .general:
            """
            SwiftyNotes CLI

            Manage the same file-backed markdown notes used by the GUI.

            Usage:
              flatpak run me.spaceinbox.swiftynotes cli <command> [options]
              swiftynotes cli <command> [options]

            Commands:
              list      List notes as JSON
              get       Print one note as JSON or raw markdown
              create    Create a new note
              update    Replace a note's markdown content
              move      Move a note to another folder
              folders   List folders, or manage them via subcommands
                        (folders create/rm/rename/move)
              help      Show general or command-specific help

            Global options:
              --notes-dir PATH   Use a custom notes directory instead of the GUI default

            Notes:
              - Note IDs are lowercase UUID strings.
              - Folder paths are slash-separated relative paths (e.g. "Work/Projects").
              - For Flathub installs, run `flatpak run me.spaceinbox.swiftynotes cli ...`.
              - To add a short host command, create `~/.local/bin/swiftynotes` that runs `flatpak run me.spaceinbox.swiftynotes "$@"`.
              - Without --notes-dir, the CLI uses the same storage directory as the GUI.
              - If host storage is empty, the CLI also checks the default Flatpak storage under ~/.var/app/me.spaceinbox.swiftynotes/.
              - JSON output is intended to be easy for scripts and AI agents to consume.

            Examples:
              swiftynotes cli list
              swiftynotes cli list --folder Work
              swiftynotes cli folders
              swiftynotes cli folders create Work/Drafts
              swiftynotes cli folders rm Work/Drafts --yes
              swiftynotes cli get 657aa2f6-0f4e-4a9c-944a-76fc94f40554
              swiftynotes cli get 657aa2f6-0f4e-4a9c-944a-76fc94f40554 --raw
              swiftynotes cli create --content '# Title\n\nBody' --folder Work/Drafts
              swiftynotes cli move 657aa2f6-0f4e-4a9c-944a-76fc94f40554 --folder Personal
              swiftynotes cli update 657aa2f6-0f4e-4a9c-944a-76fc94f40554 --stdin

            Run `swiftynotes cli help <command>` for details on a specific command.
            """
        case .list:
            """
            Usage:
              swiftynotes cli list [--folder PATH] [--notes-dir PATH]

            List notes as a JSON array.

            Options:
              --folder PATH   Limit results to notes inside the given folder
                              (the folder itself plus every descendant folder).

            Output:
              Each item includes:
              - id
              - title
              - filename
              - folder        (relative folder path, "" for root)
              - createdAt
              - updatedAt

            Examples:
              swiftynotes cli list
              swiftynotes cli list --folder Work
              swiftynotes cli list --notes-dir /path/to/notes
            """
        case .get:
            """
            Usage:
              swiftynotes cli get <note-id> [--raw] [--notes-dir PATH]

            Read one note by ID.

            Options:
              --raw   Print only markdown content instead of JSON

            Output:
              Default output is a JSON document with note metadata and content.

            Example:
              swiftynotes cli get 657aa2f6-0f4e-4a9c-944a-76fc94f40554 --raw
            """
        case .create:
            """
            Usage:
              swiftynotes cli create [--content TEXT | --content-file PATH | --stdin] [--folder PATH] [--notes-dir PATH]

            Create a new note.

            Content sources:
              --content TEXT        Use inline markdown
              --content-file PATH   Read markdown from a file
              --stdin               Read markdown from standard input

            Options:
              --folder PATH         Place the note inside the given folder, creating
                                    intermediate folders if they do not exist.

            Notes:
              - If no content source is provided, an empty note is created.
              - Output is the created note as JSON.

            Examples:
              swiftynotes cli create --content '# Title'
              swiftynotes cli create --content-file ./note.md
              swiftynotes cli create --content '# Draft' --folder Work/Drafts
              cat note.md | swiftynotes cli create --stdin --folder Inbox
            """
        case .update:
            """
            Usage:
              swiftynotes cli update <note-id> (--content TEXT | --content-file PATH | --stdin) [--notes-dir PATH]

            Replace an existing note's markdown content by ID.

            Content sources:
              --content TEXT        Use inline markdown
              --content-file PATH   Read markdown from a file
              --stdin               Read markdown from standard input

            Notes:
              - update replaces the full markdown content of the note.
              - Output is the updated note as JSON.

            Examples:
              swiftynotes cli update 657aa2f6-0f4e-4a9c-944a-76fc94f40554 --content '# Updated'
              cat note.md | swiftynotes cli update 657aa2f6-0f4e-4a9c-944a-76fc94f40554 --stdin
            """
        case .move:
            """
            Usage:
              swiftynotes cli move <note-id> --folder PATH [--notes-dir PATH]

            Move a note to another folder. Use --folder "" to move to the root.

            Notes:
              - Intermediate folders are created automatically when missing.
              - Output is the moved note as JSON.

            Examples:
              swiftynotes cli move 657aa2f6-0f4e-4a9c-944a-76fc94f40554 --folder Work/Drafts
              swiftynotes cli move 657aa2f6-0f4e-4a9c-944a-76fc94f40554 --folder ""
            """
        case .folders:
            """
            Usage:
              swiftynotes cli folders [<subcommand>] [<args>] [--notes-dir PATH]

            With no subcommand prints every folder path in the vault as a JSON
            array (empty folders included).

            Subcommands:
              create <path>                Create a folder. Errors if it already exists.
              rm <path> [-y|--yes]         Recursively delete a folder. Refuses unless
                                           the folder is empty or --yes is supplied.
              rename <path> <new-name>     Rename a folder, keeping its contents.
              move <path> --to <parent>    Move a folder under another parent
                                           (use "" for root).

            Examples:
              swiftynotes cli folders
              swiftynotes cli folders create Work/Drafts
              swiftynotes cli folders rm Work/Drafts --yes
              swiftynotes cli folders rename Work/Drafts Outbox
              swiftynotes cli folders move Outbox --to Personal
            """
        case .foldersCreate:
            """
            Usage:
              swiftynotes cli folders create <path> [--notes-dir PATH]

            Creates a folder, creating intermediate parents as needed.
            Fails when the path already exists or traverses a note directory.

            Output:
              {"action":"created","path":"<path>"}

            Example:
              swiftynotes cli folders create Work/Drafts
            """
        case .foldersRm:
            """
            Usage:
              swiftynotes cli folders rm <path> [-y|--yes] [--notes-dir PATH]

            Recursively deletes a folder. Without --yes the command refuses
            to delete a folder that still contains notes or subfolders, so
            scripts have to opt in to the destructive behaviour explicitly.

            Output:
              {"action":"deleted","path":"<path>"}

            Examples:
              swiftynotes cli folders rm Work/Drafts            # only if empty
              swiftynotes cli folders rm Work --yes             # delete recursively
            """
        case .foldersRename:
            """
            Usage:
              swiftynotes cli folders rename <path> <new-name> [--notes-dir PATH]

            Renames the folder at <path> to <new-name> (single component).
            Nested notes and subfolders keep their relative layout.

            Output:
              {"action":"renamed","path":"<path>","to":"<parent>/<new-name>"}

            Example:
              swiftynotes cli folders rename Work/Drafts Outbox
            """
        case .foldersMove:
            """
            Usage:
              swiftynotes cli folders move <path> --to <parent> [--notes-dir PATH]

            Moves the folder at <path> under <parent>. Use --to "" for the root.
            Nested notes and subfolders move with the folder.

            Output:
              {"action":"moved","path":"<path>","to":"<parent>/<last>"}

            Examples:
              swiftynotes cli folders move Outbox --to Personal
              swiftynotes cli folders move Personal/Outbox --to ""
            """
        }
    }
}

private enum NotesCLIError: Error {
    case usage(String)
    case notFound(String)
    case runtime(String)

    var message: String {
        switch self {
        case let .usage(message), let .notFound(message), let .runtime(message):
            message
        }
    }

    var exitCode: Int32 {
        switch self {
        case .usage:
            2
        case .notFound:
            3
        case .runtime:
            1
        }
    }
}

private struct ParsedInvocation {
    enum Command {
        case help(CLIHelpTopic)
        case list(folderScope: String)
        case get(UUID, raw: Bool)
        case create(String, folderPath: String)
        case update(UUID, String)
        case move(UUID, folderPath: String)
        case folders
        case foldersCreate(path: String)
        case foldersRm(path: String, yes: Bool)
        case foldersRename(path: String, newName: String)
        case foldersMove(path: String, newParent: String)
    }

    let notesDirectory: URL?
    let command: Command

    init(arguments: [String], stdin: Data?) throws {
        let (notesDirectory, remaining) = try Self.parseGlobalOptions(arguments)
        self.notesDirectory = notesDirectory

        guard let subcommand = remaining.first else {
            command = .help(.general)
            return
        }

        let args = Array(remaining.dropFirst())
        switch subcommand {
        case "help", "--help", "-h":
            command = try Self.parseHelp(args)
        case "list":
            if Self.containsHelpFlag(args) {
                command = .help(.list)
                return
            }
            command = try Self.parseList(args)
        case "folders":
            if Self.containsHelpFlag(args) {
                command = .help(.folders)
                return
            }
            command = try Self.parseFolders(args)
        case "move":
            if Self.containsHelpFlag(args) {
                command = .help(.move)
                return
            }
            command = try Self.parseMove(args)
        case "get":
            if Self.containsHelpFlag(args) {
                command = .help(.get)
                return
            }
            command = try Self.parseGet(args)
        case "create":
            if Self.containsHelpFlag(args) {
                command = .help(.create)
                return
            }
            let parsed = try Self.parseContentSourceWithFolder(args, stdin: stdin, contentRequired: false)
            command = .create(parsed.content, folderPath: parsed.folderPath)
        case "update":
            if Self.containsHelpFlag(args) {
                command = .help(.update)
                return
            }
            command = try Self.parseUpdate(args, stdin: stdin)
        default:
            throw NotesCLIError.usage("Unknown CLI command: \(subcommand)\n\n\(NotesCLI.help(for: .general))")
        }
    }

    private static func parseHelp(_ arguments: [String]) throws -> Command {
        guard arguments.count <= 1 else {
            throw NotesCLIError.usage("`help` accepts at most one command name.\n\n\(NotesCLI.help(for: .general))")
        }
        guard let topic = arguments.first else {
            return .help(.general)
        }
        switch topic {
        case "list":
            return .help(.list)
        case "get":
            return .help(.get)
        case "create":
            return .help(.create)
        case "update":
            return .help(.update)
        case "move":
            return .help(.move)
        case "folders":
            return .help(.folders)
        default:
            throw NotesCLIError.usage("Unknown command for help: \(topic)\n\n\(NotesCLI.help(for: .general))")
        }
    }

    private static func parseFolders(_ arguments: [String]) throws -> Command {
        guard let first = arguments.first else { return .folders }
        let rest = Array(arguments.dropFirst())
        switch first {
        case "create":
            if Self.containsHelpFlag(rest) { return .help(.foldersCreate) }
            return try Self.parseFoldersCreate(rest)
        case "rm", "delete":
            if Self.containsHelpFlag(rest) { return .help(.foldersRm) }
            return try Self.parseFoldersRm(rest)
        case "rename":
            if Self.containsHelpFlag(rest) { return .help(.foldersRename) }
            return try Self.parseFoldersRename(rest)
        case "move":
            if Self.containsHelpFlag(rest) { return .help(.foldersMove) }
            return try Self.parseFoldersMove(rest)
        default:
            throw NotesCLIError.usage("Unknown folders subcommand: \(first)\n\n\(NotesCLI.help(for: .folders))")
        }
    }

    private static func parseFoldersCreate(_ arguments: [String]) throws -> Command {
        guard let path = arguments.first, arguments.count == 1 else {
            throw NotesCLIError.usage("`folders create` requires exactly one folder path.\n\n\(NotesCLI.help(for: .foldersCreate))")
        }
        return .foldersCreate(path: path)
    }

    private static func parseFoldersRm(_ arguments: [String]) throws -> Command {
        var path: String?
        var yes = false
        for token in arguments {
            switch token {
            case "-y", "--yes":
                yes = true
            default:
                guard path == nil else {
                    throw NotesCLIError.usage("`folders rm` accepts exactly one folder path.\n\n\(NotesCLI.help(for: .foldersRm))")
                }
                path = token
            }
        }
        guard let path else {
            throw NotesCLIError.usage("`folders rm` requires a folder path.\n\n\(NotesCLI.help(for: .foldersRm))")
        }
        return .foldersRm(path: path, yes: yes)
    }

    private static func parseFoldersRename(_ arguments: [String]) throws -> Command {
        guard arguments.count == 2 else {
            throw NotesCLIError.usage("`folders rename` requires <path> <new-name>.\n\n\(NotesCLI.help(for: .foldersRename))")
        }
        return .foldersRename(path: arguments[0], newName: arguments[1])
    }

    private static func parseFoldersMove(_ arguments: [String]) throws -> Command {
        var path: String?
        var newParent: String?
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            if token == "--to" {
                let nextIndex = index + 1
                guard nextIndex < arguments.count else {
                    throw NotesCLIError.usage("Missing value for --to.\n\n\(NotesCLI.help(for: .foldersMove))")
                }
                newParent = arguments[nextIndex]
                index += 2
                continue
            }
            guard path == nil else {
                throw NotesCLIError.usage("`folders move` accepts exactly one folder path.\n\n\(NotesCLI.help(for: .foldersMove))")
            }
            path = token
            index += 1
        }
        guard let path, let newParent else {
            throw NotesCLIError.usage("`folders move <path> --to <parent>` requires both a path and a parent.\n\n\(NotesCLI.help(for: .foldersMove))")
        }
        return .foldersMove(path: path, newParent: newParent)
    }

    private static func parseMove(_ arguments: [String]) throws -> Command {
        var noteID: UUID?
        var folderPath: String?
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            if token == "--folder" {
                let nextIndex = index + 1
                guard nextIndex < arguments.count else {
                    throw NotesCLIError.usage("Missing value for --folder.\n\n\(NotesCLI.help(for: .move))")
                }
                folderPath = arguments[nextIndex]
                index += 2
                continue
            }
            guard noteID == nil else {
                throw NotesCLIError.usage("`move` expects exactly one note ID.\n\n\(NotesCLI.help(for: .move))")
            }
            guard let parsed = UUID(uuidString: token) else {
                throw NotesCLIError.usage("Invalid note ID: \(token)\n\n\(NotesCLI.help(for: .move))")
            }
            noteID = parsed
            index += 1
        }
        guard let noteID else {
            throw NotesCLIError.usage("`move` requires a note ID.\n\n\(NotesCLI.help(for: .move))")
        }
        guard let folderPath else {
            throw NotesCLIError.usage("`move` requires --folder PATH (use --folder \"\" to move to the root).\n\n\(NotesCLI.help(for: .move))")
        }
        return .move(noteID, folderPath: folderPath)
    }

    private static func parseList(_ arguments: [String]) throws -> Command {
        var folderScope = ""
        var index = 0
        while index < arguments.count {
            let current = arguments[index]
            if current == "--folder" {
                let nextIndex = index + 1
                guard nextIndex < arguments.count else {
                    throw NotesCLIError.usage("Missing value for --folder.\n\n\(NotesCLI.help(for: .list))")
                }
                folderScope = arguments[nextIndex]
                index += 2
                continue
            }
            throw NotesCLIError.usage("Unknown option: \(current)\n\n\(NotesCLI.help(for: .list))")
        }
        return .list(folderScope: folderScope)
    }

    private static func containsHelpFlag(_ arguments: [String]) -> Bool {
        arguments.contains("--help") || arguments.contains("-h")
    }

    private static func parseGlobalOptions(_ arguments: [String]) throws -> (URL?, [String]) {
        var notesDirectory: URL?
        var remaining: [String] = []
        var index = 0

        while index < arguments.count {
            let current = arguments[index]
            if current == "--notes-dir" {
                let nextIndex = index + 1
                guard nextIndex < arguments.count else {
                    throw NotesCLIError.usage("Missing value for --notes-dir.\n\n\(NotesCLI.help(for: .general))")
                }
                notesDirectory = URL(fileURLWithPath: arguments[nextIndex], isDirectory: true)
                index += 2
                continue
            }
            remaining.append(current)
            index += 1
        }

        return (notesDirectory, remaining)
    }

    private static func parseGet(_ arguments: [String]) throws -> Command {
        var raw = false
        var noteID: UUID?
        var index = 0

        while index < arguments.count {
            let current = arguments[index]
            switch current {
            case "--raw":
                raw = true
            default:
                guard noteID == nil else {
                    throw NotesCLIError.usage("`get` expects exactly one note ID.\n\n\(NotesCLI.help(for: .get))")
                }
                guard let parsedID = UUID(uuidString: current) else {
                    throw NotesCLIError.usage("Invalid note ID: \(current)\n\n\(NotesCLI.help(for: .get))")
                }
                noteID = parsedID
            }
            index += 1
        }

        guard let noteID else {
            throw NotesCLIError.usage("`get` requires a note ID.\n\n\(NotesCLI.help(for: .get))")
        }
        return .get(noteID, raw: raw)
    }

    private static func parseUpdate(_ arguments: [String], stdin: Data?) throws -> Command {
        guard let first = arguments.first else {
            throw NotesCLIError.usage("`update` requires a note ID.\n\n\(NotesCLI.help(for: .update))")
        }
        guard let noteID = UUID(uuidString: first) else {
            throw NotesCLIError.usage("Invalid note ID: \(first)\n\n\(NotesCLI.help(for: .update))")
        }
        let content = try parseContentSource(Array(arguments.dropFirst()), stdin: stdin, contentRequired: true)
        return .update(noteID, content)
    }

    private struct ContentAndFolder {
        let content: String
        let folderPath: String
    }

    private static func parseContentSourceWithFolder(
        _ arguments: [String],
        stdin: Data?,
        contentRequired: Bool,
    ) throws -> ContentAndFolder {
        var folderPath = ""
        var passthrough: [String] = []
        var index = 0
        while index < arguments.count {
            let current = arguments[index]
            if current == "--folder" {
                let nextIndex = index + 1
                guard nextIndex < arguments.count else {
                    let topic: CLIHelpTopic = contentRequired ? .update : .create
                    throw NotesCLIError.usage("Missing value for --folder.\n\n\(NotesCLI.help(for: topic))")
                }
                folderPath = arguments[nextIndex]
                index += 2
                continue
            }
            passthrough.append(current)
            index += 1
        }
        let content = try parseContentSource(passthrough, stdin: stdin, contentRequired: contentRequired)
        return ContentAndFolder(content: content, folderPath: folderPath)
    }

    private static func parseContentSource(
        _ arguments: [String],
        stdin: Data?,
        contentRequired: Bool,
    ) throws -> String {
        var inlineContent: String?
        var contentFile: String?
        var useStdin = false
        var index = 0

        while index < arguments.count {
            let current = arguments[index]
            switch current {
            case "--content":
                let nextIndex = index + 1
                guard nextIndex < arguments.count else {
                    let topic: CLIHelpTopic = contentRequired ? .update : .create
                    throw NotesCLIError.usage("Missing value for --content.\n\n\(NotesCLI.help(for: topic))")
                }
                inlineContent = arguments[nextIndex]
                index += 2
            case "--content-file":
                let nextIndex = index + 1
                guard nextIndex < arguments.count else {
                    let topic: CLIHelpTopic = contentRequired ? .update : .create
                    throw NotesCLIError.usage("Missing value for --content-file.\n\n\(NotesCLI.help(for: topic))")
                }
                contentFile = arguments[nextIndex]
                index += 2
            case "--stdin":
                useStdin = true
                index += 1
            default:
                let topic: CLIHelpTopic = contentRequired ? .update : .create
                throw NotesCLIError.usage("Unknown option: \(current)\n\n\(NotesCLI.help(for: topic))")
            }
        }

        let selectedSources = [inlineContent != nil, contentFile != nil, useStdin].count(where: { $0 })
        if selectedSources > 1 {
            let topic: CLIHelpTopic = contentRequired ? .update : .create
            throw NotesCLIError.usage("Use only one of --content, --content-file, or --stdin.\n\n\(NotesCLI.help(for: topic))")
        }

        if let inlineContent {
            return inlineContent
        }
        if let contentFile {
            return try String(contentsOfFile: contentFile, encoding: .utf8)
        }
        if useStdin {
            let data = stdin ?? FileHandle.standardInput.readDataToEndOfFile()
            guard let content = String(data: data, encoding: .utf8) else {
                throw NotesCLIError.runtime("Could not read UTF-8 content from stdin")
            }
            return content
        }
        if contentRequired {
            throw NotesCLIError.usage("Replacement content is required.\n\n\(NotesCLI.help(for: .update))")
        }
        return ""
    }
}

private enum CLINotesDirectoryResolver {
    private static let notesDirectoryName = "notes"
    private static let settingsFilename = "settings.json"
    private static let noteFilename = "note.md"

    static func resolve(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) -> URL {
        let hostDataHome = dataHome(in: environment, fileManager: fileManager)
        let hostConfigHome = configHome(in: environment, fileManager: fileManager)
        let hostDefaultNotesDirectory = notesDirectory(in: hostDataHome)

        if let hostSettings = loadSettings(from: hostConfigHome, fileManager: fileManager) {
            return hostSettings.resolvedNotesDirectory(defaultDirectory: hostDefaultNotesDirectory)
        }
        if hasStoredNotes(in: hostDataHome, fileManager: fileManager) {
            return hostDefaultNotesDirectory
        }
        if hasExplicitXDGOverride(in: environment) {
            return hostDefaultNotesDirectory
        }

        let flatpakRoot = flatpakRootDirectory(in: environment, fileManager: fileManager)
        let flatpakDataHome = flatpakRoot.appendingPathComponent("data", isDirectory: true)
        let flatpakConfigHome = flatpakRoot.appendingPathComponent("config", isDirectory: true)
        let flatpakDefaultNotesDirectory = notesDirectory(in: flatpakDataHome)

        if let flatpakSettings = loadSettings(from: flatpakConfigHome, fileManager: fileManager) {
            return flatpakSettings.resolvedNotesDirectory(defaultDirectory: flatpakDefaultNotesDirectory)
        }
        if hasStoredNotes(in: flatpakDataHome, fileManager: fileManager) {
            return flatpakDefaultNotesDirectory
        }

        return hostDefaultNotesDirectory
    }

    private static func loadSettings(
        from configHome: URL,
        fileManager: FileManager,
    ) -> AppSettings? {
        let settingsURL = AppIdentity.applicationDirectory(in: configHome)
            .appendingPathComponent(settingsFilename, isDirectory: false)
        guard fileManager.fileExists(atPath: settingsURL.path(percentEncoded: false)) else { return nil }
        return try? AppSettingsStore(settingsFileURL: settingsURL, fileManager: fileManager).load()
    }

    private static func hasStoredNotes(
        in dataHome: URL,
        fileManager: FileManager,
    ) -> Bool {
        let applicationIdentifiers = [AppIdentity.identifier] + AppIdentity.legacyIdentifiers
        for applicationIdentifier in applicationIdentifiers {
            let notesDirectory = AppIdentity.applicationDirectory(
                in: dataHome,
                identifier: applicationIdentifier,
            )
            .appendingPathComponent(notesDirectoryName, isDirectory: true)

            guard fileManager.fileExists(atPath: notesDirectory.path(percentEncoded: false)) else { continue }
            guard let contents = try? fileManager.contentsOfDirectory(
                at: notesDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles],
            ) else {
                continue
            }

            if contents.contains(where: { isStoredNoteEntry($0, fileManager: fileManager) }) {
                return true
            }
        }
        return false
    }

    private static func isStoredNoteEntry(
        _ entryURL: URL,
        fileManager: FileManager,
    ) -> Bool {
        if entryURL.hasDirectoryPath {
            return fileManager.fileExists(
                atPath: entryURL.appendingPathComponent(noteFilename, isDirectory: false).path(percentEncoded: false),
            )
        }
        return entryURL.pathExtension == "md"
    }

    private static func notesDirectory(in dataHome: URL) -> URL {
        AppIdentity.applicationDirectory(in: dataHome)
            .appendingPathComponent(notesDirectoryName, isDirectory: true)
            .standardizedFileURL
    }

    private static func hasExplicitXDGOverride(
        in environment: [String: String],
    ) -> Bool {
        (environment["XDG_DATA_HOME"]?.isEmpty == false)
            || (environment["XDG_CONFIG_HOME"]?.isEmpty == false)
    }

    private static func dataHome(
        in environment: [String: String],
        fileManager: FileManager,
    ) -> URL {
        xdgHome(
            variable: "XDG_DATA_HOME",
            fallbackComponents: [".local", "share"],
            environment: environment,
            fileManager: fileManager,
        )
    }

    private static func configHome(
        in environment: [String: String],
        fileManager: FileManager,
    ) -> URL {
        xdgHome(
            variable: "XDG_CONFIG_HOME",
            fallbackComponents: [".config"],
            environment: environment,
            fileManager: fileManager,
        )
    }

    private static func xdgHome(
        variable: String,
        fallbackComponents: [String],
        environment: [String: String],
        fileManager: FileManager,
    ) -> URL {
        if let configuredPath = environment[variable], !configuredPath.isEmpty {
            return URL(fileURLWithPath: configuredPath, isDirectory: true).standardizedFileURL
        }

        var directory = homeDirectory(in: environment, fileManager: fileManager)
        for component in fallbackComponents {
            directory.appendPathComponent(component, isDirectory: true)
        }
        return directory.standardizedFileURL
    }

    private static func flatpakRootDirectory(
        in environment: [String: String],
        fileManager: FileManager,
    ) -> URL {
        homeDirectory(in: environment, fileManager: fileManager)
            .appendingPathComponent(".var", isDirectory: true)
            .appendingPathComponent("app", isDirectory: true)
            .appendingPathComponent(AppIdentity.identifier, isDirectory: true)
            .standardizedFileURL
    }

    private static func homeDirectory(
        in environment: [String: String],
        fileManager: FileManager,
    ) -> URL {
        if let homePath = environment["HOME"], !homePath.isEmpty {
            return URL(fileURLWithPath: homePath, isDirectory: true).standardizedFileURL
        }
        return fileManager.homeDirectoryForCurrentUser.standardizedFileURL
    }
}

private struct CLINoteSummary: Codable {
    let id: String
    let title: String
    let filename: String
    let folder: String
    let createdAt: Date
    let updatedAt: Date

    init(note: Note) {
        id = note.stableID
        title = note.title
        filename = note.filename
        folder = note.folderPath
        createdAt = note.createdAt
        updatedAt = note.updatedAt
    }
}

private struct CLIFolderOperation: Codable {
    let action: String
    let path: String
    let to: String?
}

private struct CLINoteDocument: Codable {
    let id: String
    let title: String
    let filename: String
    let folder: String
    let createdAt: Date
    let updatedAt: Date
    let content: String

    init(note: Note) {
        id = note.stableID
        title = note.title
        filename = note.filename
        folder = note.folderPath
        createdAt = note.createdAt
        updatedAt = note.updatedAt
        content = note.content
    }
}
