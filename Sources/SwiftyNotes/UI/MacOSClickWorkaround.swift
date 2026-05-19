import Adwaita
import Foundation

/// GTK4 on Quartz has a long-standing drag-detection regression: any
/// sub-pixel pointer motion between press and release wakes up an
/// internal pan/drag gesture that races the button's own click gesture
/// for the pointer sequence. The drag gesture wins, claims the
/// sequence, and `Button.clicked` (plus the toggled/popup behaviour
/// derived from it) never fires. Symptom: toolbar buttons, mode
/// toggles, the hamburger button, and items inside hand-built menus
/// all behave as if the click was swallowed unless the cursor stays
/// perfectly still during the press.
///
/// The reliable fix used across the codebase (sidebar rows, note +
/// folder context menus, update banner, …) is:
///
///   1. Attach an explicit `GestureClick` on the **CAPTURE** phase so
///      it fires before the widget's own BUBBLE-phase gestures.
///   2. Claim the sequence the moment we observe the press
///      (`GTK_EVENT_SEQUENCE_CLAIMED`) — that denies every other
///      interested gesture (the button's internal click, any drag
///      detector that wakes up later).
///   3. Treat our own `released` signal as the click trigger.
///
/// Wrapping this once and applying everywhere avoids hand-copying the
/// pattern and forgetting `#if os(macOS)` around it. Linux falls
/// straight through to the widget's normal click path.
@MainActor
enum MacOSClickWorkaround {
    /// Wires `handler` so it fires when the user releases a primary
    /// click on `button`, even when Quartz's drag detector would
    /// otherwise eat the click.
    ///
    /// We register on BOTH the GtkButton `clicked` signal AND the
    /// CAPTURE-phase release. They cover non-overlapping triggers:
    ///
    /// * Real macOS pointer input — our CAPTURE claim denies the
    ///   button's internal gesture, so the `clicked` signal never
    ///   emits; only our `released` handler fires.
    /// * Linux pointer input — no CAPTURE gesture is installed, so
    ///   the usual `clicked` signal path runs.
    /// * Programmatic `emitClicked()` from XCTest mirror suites — no
    ///   pointer event, so the GestureClick stays silent; the
    ///   `clicked` signal handler is what makes the test trigger
    ///   reach the real callback. Without this, every macOS XCTest
    ///   that drove the toolbar / formatting / sort buttons via
    ///   `emitClicked()` broke after we rolled out the workaround.
    static func onClick(_ button: Button, handler: @escaping @MainActor () -> Void) {
        button.onClicked(handler)
        #if os(macOS)
        attachReleaseHandler(to: button) { handler() }
        #endif
    }

    /// For ToggleButton: registers `onToggled` for the actual behaviour
    /// and additionally installs a capture-phase release that forces
    /// `active = true` on click. Mirrors GTK's "linked group" feel —
    /// clicking an already-active toggle is a no-op, since the GObject
    /// `notify::active` short-circuits when the value doesn't change.
    /// Pass `togglesActive: false` (default `true`) for stand-alone
    /// toggles where clicking should flip the state both ways.
    static func onToggle(
        _ toggle: ToggleButton,
        togglesActive: Bool = true,
        handler: @escaping @MainActor () -> Void,
    ) {
        toggle.onToggled(handler)
        #if os(macOS)
        attachReleaseHandler(to: toggle) { [weak toggle] in
            guard let toggle else { return }
            if togglesActive {
                toggle.active.toggle()
            } else {
                toggle.active = true
            }
        }
        #endif
    }

    /// Forces the menu to popup on release. `MenuButton`'s normal
    /// auto-popup hangs off its internal clicked signal, which is also
    /// eaten by the drag detector on Quartz.
    static func onMenuButtonPress(_ menuButton: MenuButton) {
        #if os(macOS)
        attachReleaseHandler(to: menuButton) { [weak menuButton] in
            guard let menuButton else { return }
            gtk_menu_button_popup(menuButton.opaquePointer)
        }
        #endif
    }

#if os(macOS)
    /// Generic press/release plumbing shared by Button / ToggleButton /
    /// MenuButton. The widget keeps a strong reference to the gesture
    /// (via `addController`), so we only need a weak ref back through
    /// the closure to avoid retain cycles.
    private static func attachReleaseHandler(
        to widget: Widget,
        onRelease: @escaping @MainActor () -> Void,
    ) {
        let click = GestureClick()
        click.button = 1
        gtk_event_controller_set_propagation_phase(click.opaquePointer, GTK_PHASE_CAPTURE)
        widget.addController(click)
        click.onPressed { [weak click] _, _, _ in
            guard let click else { return }
            gtk_gesture_set_state(click.opaquePointer, GTK_EVENT_SEQUENCE_CLAIMED)
        }
        click.onReleased { _, _, _ in onRelease() }
    }
    #endif
}
