import AppKit
import Carbon
import XCTest
@testable import TokenTrackerApp

final class AppLaunchPolicyTests: XCTestCase {
    private func event(origin: OSType? = nil) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass),
                                          eventID: AEEventID(kAEOpenApplication),
                                          targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                          transactionID: AETransactionID(kAnyTransactionID))
        if let origin {
            event.setParam(NSAppleEventDescriptor(enumCode: origin), forKeyword: keyAEPropData)
        }
        return event
    }

    func testManualLaunchShowsDashboard() {
        XCTAssertTrue(AppLaunchPolicy.showsMainWindow(for: event()))
        XCTAssertTrue(AppLaunchPolicy.showsMainWindow(for: nil))
    }

    func testLoginAndServiceLaunchStayInMenuBar() {
        XCTAssertFalse(AppLaunchPolicy.showsMainWindow(for: event(origin: keyAELaunchedAsLogInItem)))
        XCTAssertFalse(AppLaunchPolicy.showsMainWindow(for: event(origin: keyAELaunchedAsServiceItem)))
    }
}
