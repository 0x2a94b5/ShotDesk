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

    func testScreenLocalRectMapsToRetinaSnapshotPixels() {
        let result = Geometry.screenLocalToImagePixels(
            CGRect(x: 100, y: 50, width: 640, height: 360),
            screenSize: CGSize(width: 1440, height: 900),
            imageSize: CGSize(width: 2880, height: 1800)
        )

        XCTAssertEqual(result, CGRect(x: 200, y: 100, width: 1280, height: 720))
    }

    func testScreenLocalRectIsClampedToSnapshotBounds() {
        let result = Geometry.screenLocalToImagePixels(
            CGRect(x: 1900, y: 1000, width: 100, height: 100),
            screenSize: CGSize(width: 1920, height: 1080),
            imageSize: CGSize(width: 1920, height: 1080)
        )

        XCTAssertEqual(result, CGRect(x: 1900, y: 1000, width: 20, height: 80))
    }

    func testTaperedArrowKeepsTheUserDrawnLength() {
        let points = AnnotationRenderer.taperedArrowPoints(
            from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0), lineWidth: 3
        )

        XCTAssertEqual(points.first, CGPoint(x: 0, y: 0))
        XCTAssertEqual(points[3], CGPoint(x: 100, y: 0))
    }

    func testTaperedArrowUsesSymmetricHead() {
        let points = AnnotationRenderer.taperedArrowPoints(
            from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0), lineWidth: 3
        )

        XCTAssertEqual(points[2].x, points[4].x, accuracy: 0.001)
        XCTAssertEqual(points[2].y, -points[4].y, accuracy: 0.001)
    }

    func testLongTaperedArrowUsesACompactHead() {
        let points = AnnotationRenderer.taperedArrowPoints(
            from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0), lineWidth: 3
        )

        XCTAssertEqual(points[2].x, 85, accuracy: 0.001)
    }
}
