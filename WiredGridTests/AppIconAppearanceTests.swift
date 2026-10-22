import AppKit
import XCTest
@testable import WiredGrid

final class AppIconAppearanceTests: XCTestCase {
    func testDarkIconIsBundled() throws {
        let image = try XCTUnwrap(NSImage(named: "AppIconDark"))
        XCTAssertEqual(image.size, NSSize(width: 512, height: 512))
    }

    func testDetectsAppearance() {
        XCTAssertTrue(AppIconAppearance.isDark(NSAppearance(named: .darkAqua)!))
        XCTAssertTrue(AppIconAppearance.isDark(NSAppearance(named: .vibrantDark)!))
        XCTAssertFalse(AppIconAppearance.isDark(NSAppearance(named: .aqua)!))
    }
}
