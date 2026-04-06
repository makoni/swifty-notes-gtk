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
}

enum NotesCLI {
    static func runIfRequested(
        arguments: [String],
        stdin: Data? = nil
    ) -> NotesCLIExecutionResult? {
        guard arguments.first == "cli" else { return nil }
        return run(arguments: Array(arguments.dropFirst()), stdin: stdin)
    }

    private static func run(
        arguments: [String],
        stdin: Data?
    ) -> NotesCLIExecutionResult {
        do {
            let parsed = try ParsedInvocation(arguments: arguments, stdin: stdin)
            let repository = NotesRepository(
                notesDirectory: parsed.notesDirectory ?? NotesRepository.defaultNotesDirectory()
            )

            let output: String
            switch parsed.command {
            case let .help(topic):
                output = help(for: topic)
            case .list:
                let notes = try repository.loadNotes()
                output = try encodeJSON(notes.map(CLINoteSummary.init))
            case let .get(noteID, raw):
                let note = try loadNote(id: noteID, repository: repository)
                output = raw ? note.content : try encodeJSON(CLINoteDocument(note: note))
            case let .create(content):
                let note = try repository.createNote(initialContent: content)
                output = try encodeJSON(CLINoteDocument(note: note))
            case let .update(noteID, content):
                var note = try loadNote(id: noteID, repository: repository)
                note.content = content
                let saved = try repository.save(note: note)
                output = try encodeJSON(CLINoteDocument(note: saved))
            }

            return .init(
                exitCode: 0,
                stdout: output.hasSuffix("\n") ? output : "\(output)\n",
                stderr: ""
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

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
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
              SwiftyNotes cli <command> [options]

            Commands:
              list      List notes as JSON
              get       Print one note as JSON or raw markdown
              create    Create a new note
              update    Replace a note's markdown content
              help      Show general or command-specific help

            Global options:
              --notes-dir PATH   Use a custom notes directory instead of the GUI default

            Notes:
              - Note IDs are lowercase UUID strings.
              - Without --notes-dir, the CLI uses the same storage directory as the GUI.
              - JSON output is intended to be easy for scripts and AI agents to consume.

            Examples:
              SwiftyNotes cli list
              SwiftyNotes cli get 657aa2f6-0f4e-4a9c-944a-76fc94f40554
              SwiftyNotes cli get 657aa2f6-0f4e-4a9c-944a-76fc94f40554 --raw
              SwiftyNotes cli create --content '# Title\n\nBody'
              SwiftyNotes cli update 657aa2f6-0f4e-4a9c-944a-76fc94f40554 --stdin

            Run `SwiftyNotes cli help <command>` for details on a specific command.
            """
        case .list:
            """
            Usage:
              SwiftyNotes cli list [--notes-dir PATH]

            List all notes as a JSON array.

            Output:
              Each item includes:
              - id
              - title
              - filename
              - createdAt
              - updatedAt

            Example:
              SwiftyNotes cli list --notes-dir /path/to/notes
            """
        case .get:
            """
            Usage:
              SwiftyNotes cli get <note-id> [--raw] [--notes-dir PATH]

            Read one note by ID.

            Options:
              --raw   Print only markdown content instead of JSON

            Output:
              Default output is a JSON document with note metadata and content.

            Example:
              SwiftyNotes cli get 657aa2f6-0f4e-4a9c-944a-76fc94f40554 --raw
            """
        case .create:
            """
            Usage:
              SwiftyNotes cli create [--content TEXT | --content-file PATH | --stdin] [--notes-dir PATH]

            Create a new note.

            Content sources:
              --content TEXT        Use inline markdown
              --content-file PATH   Read markdown from a file
              --stdin               Read markdown from standard input

            Notes:
              - If no content source is provided, an empty note is created.
              - Output is the created note as JSON.

            Examples:
              SwiftyNotes cli create --content '# Title'
              SwiftyNotes cli create --content-file ./note.md
              cat note.md | SwiftyNotes cli create --stdin
            """
        case .update:
            """
            Usage:
              SwiftyNotes cli update <note-id> (--content TEXT | --content-file PATH | --stdin) [--notes-dir PATH]

            Replace an existing note's markdown content by ID.

            Content sources:
              --content TEXT        Use inline markdown
              --content-file PATH   Read markdown from a file
              --stdin               Read markdown from standard input

            Notes:
              - update replaces the full markdown content of the note.
              - Output is the updated note as JSON.

            Examples:
              SwiftyNotes cli update 657aa2f6-0f4e-4a9c-944a-76fc94f40554 --content '# Updated'
              cat note.md | SwiftyNotes cli update 657aa2f6-0f4e-4a9c-944a-76fc94f40554 --stdin
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
        case list
        case get(UUID, raw: Bool)
        case create(String)
        case update(UUID, String)
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
            guard args.isEmpty else {
                throw NotesCLIError.usage("`list` does not accept positional arguments.\n\n\(NotesCLI.help(for: .list))")
            }
            command = .list
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
            command = .create(try Self.parseContentSource(args, stdin: stdin, contentRequired: false))
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
        default:
            throw NotesCLIError.usage("Unknown command for help: \(topic)\n\n\(NotesCLI.help(for: .general))")
        }
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

    private static func parseContentSource(
        _ arguments: [String],
        stdin: Data?,
        contentRequired: Bool
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

        let selectedSources = [inlineContent != nil, contentFile != nil, useStdin].filter { $0 }.count
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

private struct CLINoteSummary: Codable {
    let id: String
    let title: String
    let filename: String
    let createdAt: Date
    let updatedAt: Date

    init(note: Note) {
        id = note.stableID
        title = note.title
        filename = note.filename
        createdAt = note.createdAt
        updatedAt = note.updatedAt
    }
}

private struct CLINoteDocument: Codable {
    let id: String
    let title: String
    let filename: String
    let createdAt: Date
    let updatedAt: Date
    let content: String

    init(note: Note) {
        id = note.stableID
        title = note.title
        filename = note.filename
        createdAt = note.createdAt
        updatedAt = note.updatedAt
        content = note.content
    }
}
