import Foundation

/// Which mode this build runs in.
///
/// `isLocalOnly` is true exactly when the `LOCAL_ONLY` compile condition is set (see the
/// `AnimalTracker` target in `project.yml`). A local-only build keeps every record on the device:
/// it offers no sign-in and never syncs.
///
/// Removing the flag re-enables sign-in and sync. Do not remove it until the data-adoption defect
/// recorded in Task 6 of the local-only MVP plan is fixed: until then, signing in would not adopt
/// the records created while the app ran local-only.
enum AppMode {
    static var isLocalOnly: Bool {
        #if LOCAL_ONLY
        return true
        #else
        return false
        #endif
    }
}
