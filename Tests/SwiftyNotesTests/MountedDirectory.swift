import Foundation

/// Deletes `directory` — unless a file system is still mounted at or inside
/// it. A session's document portal mounts a FUSE file system in its runtime
/// directory that leads into the user's real folders; deleting through it
/// deletes those. `mountinfo` stands in for `/proc/self/mountinfo`.
func removeUnlessMountedInto(_ directory: URL, mountinfo: String? = nil) {
    let path = directory.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
    let mountinfo = mountinfo ?? (try? String(contentsOfFile: "/proc/self/mountinfo", encoding: .utf8)) ?? ""
    guard !MountedDirectory.hasMount(atOrInside: path, mountinfo: mountinfo) else {
        FileHandle.standardError.write(Data("tests: a file system is still mounted in \(path); left in place\n".utf8))
        return
    }
    try? FileManager.default.removeItem(at: directory)
}

/// Reading `/proc/self/mountinfo`.
enum MountedDirectory {
    /// Whether anything in `mountinfo` is mounted at `path` or below it.
    static func hasMount(atOrInside path: String, mountinfo: String) -> Bool {
        let directory = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        return mountPoints(in: mountinfo).contains { $0 == directory || $0.hasPrefix(directory + "/") }
    }

    /// The mount points `mountinfo` lists (its fifth field), unescaped.
    static func mountPoints(in mountinfo: String) -> [String] {
        mountinfo.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ")
            return fields.count > 4 ? unescaped(fields[4]) : nil
        }
    }

    /// The kernel writes a space, tab, newline or backslash in a path as
    /// `\` and three octal digits.
    private static func unescaped(_ field: Substring) -> String {
        var bytes: [UInt8] = []
        var rest = Array(field.utf8)[...]
        while let byte = rest.popFirst() {
            let digits = rest.prefix(3)
            if byte == UInt8(ascii: "\\"), digits.count == 3,
               digits.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "7")).contains($0) }),
               let value = UInt8(String(decoding: digits, as: UTF8.self), radix: 8) {
                bytes.append(value)
                rest = rest.dropFirst(3)
            } else {
                bytes.append(byte)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
