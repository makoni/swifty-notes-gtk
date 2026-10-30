import Foundation
import Testing

/// The check that keeps a test's cleanup from deleting through a mount.
struct MountedDirectoryTests {
    private static func line(_ mountPoint: String) -> String {
        "36 35 0:42 / \(mountPoint) rw,nosuid,nodev - fuse.portal portal rw,user_id=1000"
    }

    @Test("A mount inside the directory, or at it, keeps the directory")
    func aMountInsideOrAtTheDirectoryCounts() {
        let mountinfo = [Self.line("/"), Self.line("/tmp/run/doc")].joined(separator: "\n")
        #expect(MountedDirectory.hasMount(atOrInside: "/tmp/run", mountinfo: mountinfo))
        #expect(MountedDirectory.hasMount(atOrInside: "/tmp/run/", mountinfo: mountinfo))
        #expect(MountedDirectory.hasMount(atOrInside: "/tmp/run/doc", mountinfo: mountinfo))
    }

    @Test("A sibling whose name only starts the same is not inside")
    func aSiblingIsNotInside() {
        let mountinfo = [Self.line("/"), Self.line("/tmp/runtime2/doc")].joined(separator: "\n")
        #expect(!MountedDirectory.hasMount(atOrInside: "/tmp/runtime", mountinfo: mountinfo))
        #expect(!MountedDirectory.hasMount(atOrInside: "/tmp/runtime/", mountinfo: mountinfo))
    }

    @Test("Escaped characters in a mount point are read back")
    func escapedCharactersAreReadBack() {
        let mountinfo = Self.line(#"/tmp/my\040run/a\011b\134c"#)
        #expect(MountedDirectory.mountPoints(in: mountinfo) == ["/tmp/my run/a\tb\\c"])
        #expect(MountedDirectory.hasMount(atOrInside: "/tmp/my run", mountinfo: mountinfo))
        // Not an escape: fewer than three octal digits.
        #expect(MountedDirectory.mountPoints(in: Self.line(#"/tmp/a\09"#)) == [#"/tmp/a\09"#])
    }

    @Test("A directory reached through a symlinked parent is checked at its real path")
    func aDirectoryUnderASymlinkIsCheckedAtItsRealPath() throws {
        let base = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("real", isDirectory: true)
        let doc = real.appendingPathComponent("inner/doc", isDirectory: true)
        try FileManager.default.createDirectory(at: doc, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        // mountinfo names real paths: unresolved, `link/inner` would not
        // match, and the delete would go through the link into the mount.
        let mountinfo = Self.line(doc.resolvingSymlinksInPath().path(percentEncoded: false))

        removeUnlessMountedInto(link.appendingPathComponent("inner", isDirectory: true), mountinfo: mountinfo)
        #expect(FileManager.default.fileExists(atPath: doc.path(percentEncoded: false)))
    }

    @Test("Mounts that cannot be read keep the directory")
    func unreadableMountsKeepTheDirectory() throws {
        let base = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        removeUnlessMountedInto(base, mountinfo: nil)
        #expect(FileManager.default.fileExists(atPath: base.path(percentEncoded: false)))
        // Readable and nothing mounted there: it goes.
        removeUnlessMountedInto(base, mountinfo: Self.line("/"))
        #expect(!FileManager.default.fileExists(atPath: base.path(percentEncoded: false)))
    }

    @Test("Deleting leaves alone what is on another device")
    func deletingLeavesAloneWhatIsOnAnotherDevice() throws {
        let base = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("inner/file.txt", isDirectory: false)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: file)
        var info = stat()
        try #require(lstat(base.path(percentEncoded: false), &info) == 0)

        // Every entry looks like a mount point of another file system.
        #expect(!MountedDirectory.remove(base.path(percentEncoded: false), onDevice: info.st_dev &+ 1))
        #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        #expect(MountedDirectory.remove(base.path(percentEncoded: false), onDevice: info.st_dev))
        #expect(!FileManager.default.fileExists(atPath: base.path(percentEncoded: false)))
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
