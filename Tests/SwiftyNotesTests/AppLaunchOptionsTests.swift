import Foundation
@testable import SwiftyNotes
import Testing

struct AppLaunchOptionsTests {
    @Test("Empty argument list yields default options")
    func emptyArgumentListYieldsDefaultOptions() {
        let opts = AppLaunchOptions.parse(arguments: [])
        #expect(!opts.forceUpdateAvailable)
        #expect(opts.passthroughArguments == [])
    }

    @Test("Recognizes --force-update-available flag and strips it")
    func recognizesForceUpdateAvailableFlagAndStripsIt() {
        let opts = AppLaunchOptions.parse(arguments: ["--force-update-available"])
        #expect(opts.forceUpdateAvailable)
        #expect(opts.passthroughArguments == [])
    }

    @Test("Keeps other arguments untouched when stripping the flag")
    func keepsOtherArgumentsUntouchedWhenStrippingTheFlag() {
        let opts = AppLaunchOptions.parse(arguments: ["--gtk-debug=warnings", "--force-update-available", "note.md"])
        #expect(opts.forceUpdateAvailable)
        #expect(opts.passthroughArguments == ["--gtk-debug=warnings", "note.md"])
    }

    @Test("Does not match unrelated --force prefix")
    func doesNotMatchUnrelatedForcePrefix() {
        let opts = AppLaunchOptions.parse(arguments: ["--force"])
        #expect(!opts.forceUpdateAvailable)
        #expect(opts.passthroughArguments == ["--force"])
    }
}
