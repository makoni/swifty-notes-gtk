import CAdwaita
import Foundation

private let snapshotWarningFragment = "Trying to snapshot"
private let allocationWarningFragment = "without a current allocation"

private let logWriter: GLogWriterFunc = { level, fields, nFields, _ in
    var messagePointer: UnsafePointer<CChar>? = nil
    for i in 0 ..< Int(nFields) {
        let field = fields!.advanced(by: i).pointee
        if let key = field.key, String(cString: key) == "MESSAGE" {
            messagePointer = field.value?.assumingMemoryBound(to: CChar.self)
            break
        }
    }
    if let messagePointer {
        let message = String(cString: messagePointer)
        if message.contains(snapshotWarningFragment),
           message.contains(allocationWarningFragment),
           ScrollbarGizmoWarningFilter.isScrolledWindowInternal(message: message) {
            return G_LOG_WRITER_HANDLED
        }
    }
    return g_log_writer_default(level, fields, nFields, nil)
}

enum ScrollbarGizmoWarningFilter {
    private static nonisolated(unsafe) var installed = false

    static func installIfNeeded() {
        guard !installed else { return }
        installed = true
        g_log_set_writer_func(logWriter, nil, nil)
    }

    static func isScrolledWindowInternal(message: String) -> Bool {
        guard let pointerString = extractPointer(from: message),
              let address = UInt(pointerString.dropFirst(2), radix: 16),
              let widget = UnsafeMutableRawPointer(bitPattern: address) else {
            return false
        }
        var current: UnsafeMutableRawPointer? = widget
        var depth = 0
        while let ptr = current, depth < 8 {
            let typeName = g_type_name_from_instance(ptr.assumingMemoryBound(to: GTypeInstance.self))
                .map { String(cString: $0) } ?? ""
            if typeName == "GtkScrolledWindow" || typeName == "GtkScrollbar" {
                return true
            }
            let widgetPtr = ptr.assumingMemoryBound(to: GtkWidget.self)
            if let parent = gtk_widget_get_parent(widgetPtr) {
                current = UnsafeMutableRawPointer(parent)
            } else {
                current = nil
            }
            depth += 1
        }
        return false
    }

    private static func extractPointer(from message: String) -> String? {
        guard let range = message.range(of: "0x") else { return nil }
        let tail = message[range.lowerBound...]
        let endIndex = tail.firstIndex(where: { !$0.isHexDigit && $0 != "x" }) ?? tail.endIndex
        return String(tail[..<endIndex])
    }
}

private extension Character {
    var isHexDigit: Bool {
        isASCII && (isNumber || ("a"..."f").contains(lowercased().first ?? " "))
    }
}
