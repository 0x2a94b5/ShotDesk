import CoreGraphics
import XCTest
@testable import ShotDesk

final class GeometryTests: XCTestCase {
    func testMainScreenLocalRectMapsDirectlyToCGCoordinates() {
        let result = Geometry.screenLocalToCG(
            CGRect(x: 120, y: 80, width: 640, height: 360),
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            primaryMaxY: 900
        )

        XCTAssertEqual(result, CGRect(x: 120, y: 80, width: 640, height: 360))
    }

    func testRightScreenWithLowerBottomMapsFromItsOwnTopLeft() {
        let result = Geometry.screenLocalToCG(
            CGRect(x: 100, y: 50, width: 800, height: 500),
            screenFrame: CGRect(x: 1440, y: -180, width: 1920, height: 1080),
            primaryMaxY: 900
        )

        XCTAssertEqual(result, CGRect(x: 1540, y: 50, width: 800, height: 500))
    }

    func testScreenAbovePrimaryGetsNegativeCGOrigin() {
        let result = Geometry.screenLocalToCG(
            CGRect(x: 10, y: 20, width: 300, height: 200),
            screenFrame: CGRect(x: 0, y: 900, width: 1920, height: 1080),
            primaryMaxY: 900
        )

        XCTAssertEqual(result, CGRect(x: 10, y: -1060, width: 300, height: 200))
    }

    func testScreenLeftOfPrimaryKeepsNegativeGlobalX() {
        let result = Geometry.screenLocalToCG(
            CGRect(x: 40, y: 30, width: 500, height: 400),
            screenFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            primaryMaxY: 900
        )

        XCTAssertEqual(result, CGRect(x: -1880, y: -150, width: 500, height: 400))
    }
}
