import AppKit
import Carbon

/// A deliberate launch opens the dashboard; login and service launches stay quiet.
enum AppLaunchPolicy {
    static func showsMainWindow(for event: NSAppleEventDescriptor?) -> Bool {
        guard event?.eventID == kAEOpenApplication else { return true }
        let origin = event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
        return origin != keyAELaunchedAsLogInItem && origin != keyAELaunchedAsServiceItem
    }
}
