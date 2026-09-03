import Adwaita
import Foundation

/// Converts Foundation file-system errors raised while changing the notes
/// folder into copy that's actually useful to a user. Foundation surfaces
/// most permission and cross-device failures as `NSCocoaErrorDomain` codes
/// in the 5xx/6xx range with bodies like "The operation could not be
/// completed. (NSCocoaErrorDomain error 512.)" — fine for telemetry, not
/// fine for an end-user dialog.
public enum NotesDirectoryErrorMessage {
    public static func userFriendly(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case 257, 512, 513:
                return "Swifty Notes does not have permission to access that folder. Try choosing a different location.".localized
            case 640:
                return "There is not enough disk space to move your notes to that folder.".localized
            case 642:
                return "The selected folder is on a read-only filesystem and cannot store notes.".localized
            default:
                break
            }
        }
        return error.localizedDescription
    }
}
