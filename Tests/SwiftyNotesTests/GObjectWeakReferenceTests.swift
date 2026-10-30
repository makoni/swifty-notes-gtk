import CAdwaita
@testable import SwiftyNotes
import Testing

struct GObjectWeakReferenceTests {
    @Test("A weak reference reads the object while it lives, and nil once it is finalized")
    func aWeakReferenceReadsNilOnceTheObjectIsGone() throws {
        let object = try #require(g_object_new_with_properties(g_object_get_type(), 0, nil, nil))
        let pointer = UnsafeMutableRawPointer(object)
        let reference = GObjectWeakReference(pointer)
        #expect(reference.withObject { $0 } == pointer)
        // Reading holds the object only for the call.
        #expect(object.pointee.ref_count == 1)
        g_object_unref(pointer)
        #expect(reference.withObject { $0 } == nil)
    }
}
