import Adwaita
import CAdwaita

/// Tells its observers when the desktop's interface font or its resolution
/// changes, which resizes text without any CSS class changing (formulas are
/// laid out at a pixel size and follow it). Observers are held weakly
/// through an owner: once it is gone its handler is dropped. One pair of
/// GtkSettings connections serves them all, made on first use.
@MainActor
final class DesktopFontSettings {
    static let shared = DesktopFontSettings()

    private struct Observer {
        weak var owner: AnyObject?
        let handler: @MainActor () -> Void
    }

    private var observers: [Observer] = []
    /// Observers alive at the last sweep.
    private var liveObservers = 0
    private var isConnected = false

    func observe(owner: AnyObject, _ handler: @escaping @MainActor () -> Void) {
        // Dropping the dead ones once the list has doubled keeps a sidebar
        // of many formula titles from sweeping it on every row.
        if observers.count >= max(64, 2 * liveObservers) {
            observers.removeAll { $0.owner == nil }
            liveObservers = observers.count
        }
        observers.append(Observer(owner: owner, handler: handler))
        connectIfNeeded()
    }

    private func notifyObservers() {
        observers.removeAll { $0.owner == nil }
        liveObservers = observers.count
        for observer in observers {
            observer.handler()
        }
    }

    private func connectIfNeeded() {
        guard !isConnected, let settings = gtk_settings_get_default() else { return }
        isConnected = true
        let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = {
            _, _, _ in
            MainActor.assumeIsolated {
                DesktopFontSettings.shared.notifyObservers()
            }
        }
        for property in ["notify::gtk-font-name", "notify::gtk-xft-dpi"] {
            g_signal_connect_data(
                UnsafeMutableRawPointer(settings),
                property,
                unsafeBitCast(callback, to: GCallback.self),
                nil,
                nil,
                GConnectFlags(rawValue: 0)
            )
        }
    }
}
