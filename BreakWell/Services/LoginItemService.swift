import Foundation
import ServiceManagement
import os

// MARK: - LoginItemService
//
// Purpose: Toggle BreakWell's "launch at login" behavior via Apple's
// modern ServiceManagement framework.
//
// Architecture role: Thin wrapper around SMAppService.mainApp. Exposed
// for Settings UI to call when the user toggles the "Launch at login"
// checkbox.
//
// Key types defined:
//   - LoginItemService: @MainActor class
//
// Used by:
//   - SettingsView (reads isEnabled, calls set(enabled:))
//   - BreakWellApp (constructs)
//
// Swift / macOS concepts a learner will see here:
//   - `SMAppService.mainApp`: the modern (macOS 13+) launch-at-login API.
//     Replaces the deprecated `SMLoginItemSetEnabled` from earlier macOS.
//     The system handles the launch item file itself — we just register
//     or unregister.
//   - `status == .enabled`: the API has a richer state than a Bool. Other
//     values include `.notRegistered`, `.notFound`, `.requiresApproval`
//     (user has to confirm in System Settings). We treat anything other
//     than `.enabled` as "off" for UI purposes.
//   - `try ... register()` / `unregister()` are throwing because the
//     system can refuse (sandboxing, signing, parental controls, etc.).
//     We log the error and silently keep the previous state — there's
//     no good user-facing recovery for this in a checkbox UI.

/// Wraps SMAppService.mainApp for the "Launch at login" Settings toggle.
///
/// Example usage:
/// ```swift
/// let login = LoginItemService()
/// Toggle("Launch at login", isOn: Binding(
///     get: { login.isEnabled },
///     set: { login.set(enabled: $0) }
/// ))
/// ```
@MainActor
final class LoginItemService {
    private let logger = Logger(subsystem: "com.prabin.BreakWell", category: "login")

    /// True when the app is registered to launch at user login. Read each
    /// time the UI needs the value — the underlying state can change from
    /// System Settings while we're running.
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Register or unregister the app as a login item.
    /// Errors are logged but not thrown — the caller is a Settings toggle
    /// that has no useful way to surface failures other than the next
    /// `isEnabled` read showing the previous state.
    func set(enabled: Bool) {
        do {
            if enabled {
                // Guard prevents redundant register calls — the API
                // tolerates them but they show up as no-op log noise.
                guard SMAppService.mainApp.status != .enabled else { return }
                try SMAppService.mainApp.register()
                logger.info("registered for launch at login")
            } else {
                guard SMAppService.mainApp.status == .enabled else { return }
                try SMAppService.mainApp.unregister()
                logger.info("unregistered from launch at login")
            }
        } catch {
            // Common reasons: app isn't signed for distribution, or the
            // user has it disabled in System Settings > Login Items.
            logger.error("set(enabled: \(enabled)) failed: \(error.localizedDescription)")
        }
    }
}
