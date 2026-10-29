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

    @Test("A directory reached through a symlink is checked at its real path")
    func aSymlinkedDirectoryIsCheckedAtItsRealPath() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let real = base.appendingPathComponent("real", isDirectory: true)
        let link = base.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let realPath = real.resolvingSymlinksInPath().path(percentEncoded: false)
        let realMount = Self.line(realPath.hasSuffix("/") ? realPath + "doc" : realPath + "/doc")

        // Mounted inside by its real path: reached through the link, it stays.
        removeUnlessMountedInto(link, mountinfo: realMount)
        #expect(FileManager.default.fileExists(atPath: real.path(percentEncoded: false)))
        // Nothing mounted: it goes.
        removeUnlessMountedInto(real, mountinfo: Self.line("/"))
        #expect(!FileManager.default.fileExists(atPath: real.path(percentEncoded: false)))
    }
}
