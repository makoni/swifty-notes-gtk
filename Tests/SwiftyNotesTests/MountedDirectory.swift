import Foundation

/// Deletes `directory` — unless a file system is mounted at or inside it,
/// or the mounts cannot be read. A session's document portal mounts a FUSE
/// file system in its runtime directory that leads into the user's real
/// folders; deleting through it deletes those. A mount that appears after
/// the check is not crossed either.
///
/// `mountinfo` stands in for `/proc/self/mountinfo`; `nil` is a file that
/// could not be read (so on macOS nothing is deleted).
func removeUnlessMountedInto(_ directory: URL, mountinfo: String? = MountedDirectory.currentMountinfo()) {
    let path = directory.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
    guard let mountinfo else {
        FileHandle.standardError.write(Data("tests: the mounts could not be read; \(path) left in place\n".utf8))
        return
    }
    guard !MountedDirectory.hasMount(atOrInside: path, mountinfo: mountinfo) else {
        FileHandle.standardError.write(Data("tests: a file system is still mounted in \(path); left in place\n".utf8))
        return
    }
    var info = stat()
    guard lstat(path, &info) == 0 else { return }
    MountedDirectory.remove(path, onDevice: info.st_dev)
}

/// Reading `/proc/self/mountinfo`, and deleting without leaving a device.
enum MountedDirectory {
    static func currentMountinfo() -> String? {
        try? String(contentsOfFile: "/proc/self/mountinfo", encoding: .utf8)
    }

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

    /// Deletes `path` and what it holds, leaving alone anything on another
    /// device than `device` (a mount point, and so what is behind it).
    /// Returns whether everything went.
    @discardableResult
    static func remove(_ path: String, onDevice device: dev_t) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_dev == device else { return false }
        guard info.st_mode & S_IFMT == S_IFDIR else { return unlink(path) == 0 }
        var removedAll = true
        for entry in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
            removedAll = remove(path + "/" + entry, onDevice: device) && removedAll
        }
        return removedAll && rmdir(path) == 0
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
