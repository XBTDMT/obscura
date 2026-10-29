public import Foundation

public enum FolderAccessState: Sendable, Hashable {
    /// Listing the folder succeeded. This is also what triggers the TCC prompt the first time.
    case granted
    /// The folder exists but macOS refused the listing (EPERM / EACCES / the Cocoa permission errors).
    case denied
    /// There is no directory at that path.
    case missing
}

/// Probes whether we can read a folder. Call it on purpose during onboarding (it is the TCC trigger for
/// Desktop/Downloads) and again on every launch and maintenance tick, because a grant can be revoked later
/// while FSEvents keeps delivering paths for a folder we can no longer read.
public enum FolderAccess {
    public static func probe(_ url: URL) -> FolderAccessState {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .missing
        }
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: url.path)
            return .granted
        } catch {
            return classify(error as NSError)
        }
    }

    static func classify(_ error: NSError) -> FolderAccessState {
        if error.domain == NSCocoaErrorDomain {
            switch error.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError, NSFileReadInvalidFileNameError:
                return .missing
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return .denied
            default:
                break
            }
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
                return classify(underlying)
            }
        }
        if error.domain == NSPOSIXErrorDomain {
            switch Int32(error.code) {
            case ENOENT, ENOTDIR: return .missing
            case EPERM, EACCES: return .denied
            default: break
            }
        }
        // Anything else means the folder exists and we still could not read it: surface it as denied so the
        // app shows "Needs attention" rather than pretending protection is on.
        return .denied
    }
}
