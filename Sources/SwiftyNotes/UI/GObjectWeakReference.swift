import CAdwaita

/// A weak reference to a GObject (a `GWeakRef`): it never keeps the object
/// alive, and once the object is finalized it reads nil — rather than a
/// dangling pointer, or a new object that happens to land at the same
/// address.
final class GObjectWeakReference {
    /// `GWeakRef` must not move once initialised, hence its own allocation.
    private let reference = UnsafeMutablePointer<GWeakRef>.allocate(capacity: 1)

    init(_ object: UnsafeMutableRawPointer) {
        reference.initialize(to: GWeakRef())
        g_weak_ref_init(reference, object)
    }

    deinit {
        g_weak_ref_clear(reference)
        reference.deallocate()
    }

    /// Calls `body` with the object, held for the call, or with nil once it
    /// is gone.
    func withObject<Result>(_ body: (UnsafeMutableRawPointer?) -> Result) -> Result {
        let object = g_weak_ref_get(reference)
        defer {
            if let object { g_object_unref(object) }
        }
        return body(object)
    }
}
