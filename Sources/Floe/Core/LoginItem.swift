import ServiceManagement

/// Opening Floe at login, through the system's login items.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// macOS asks the user to allow it in System Settings › General › Login Items.
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.info("LoginItem: \(enabled ? "registered" : "unregistered")")
        } catch {
            Log.error("LoginItem: could not \(enabled ? "register" : "unregister"): \(error)")
        }
    }
}
