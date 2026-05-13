import Foundation
import ServiceManagement
import os

@MainActor
final class LoginItemService {
    private let logger = Logger(subsystem: "com.prabin.BreakWell", category: "login")

    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func set(enabled: Bool) {
        do {
            if enabled {
                guard SMAppService.mainApp.status != .enabled else { return }
                try SMAppService.mainApp.register()
                logger.info("registered for launch at login")
            } else {
                guard SMAppService.mainApp.status == .enabled else { return }
                try SMAppService.mainApp.unregister()
                logger.info("unregistered from launch at login")
            }
        } catch {
            logger.error("set(enabled: \(enabled)) failed: \(error.localizedDescription)")
        }
    }
}
