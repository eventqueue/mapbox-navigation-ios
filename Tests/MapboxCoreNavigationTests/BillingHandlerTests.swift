import Foundation
import XCTest
import CoreLocation
import TestHelper
import MapboxNavigationNative
import MapboxDirections
@testable import MapboxCoreNavigation

final class BillingHandlerUnitTests: TestCase {
    private var billingService: BillingServiceMock!
    private var handler: BillingHandler!
    private let freeRideToken = UUID().uuidString
    private let activeGuidanceToken = UUID().uuidString

    override func setUp() {
        super.setUp()
        billingService = .init()
        handler = BillingHandler.__createMockedHandler(with: billingService)
        billingService.onGetSKUTokenIfValid = { [unowned self] sessionType in
            switch sessionType {
            case .activeGuidance: return activeGuidanceToken
            case .freeDrive: return freeRideToken
            }
        }
    }

    override func tearDown() {
        super.tearDown()
        billingService = nil
        handler = nil
    }

    func testSessionStop() {
        let cancelSessionCalled = expectation(description: "Cancel session called")
        let billingEventTriggered = expectation(description: "Billing event triggered")
        billingService.onTriggerBillingEvent = { _ in
            billingEventTriggered.fulfill()
        }
        billingService.onStopBillingSession = { _ in
            cancelSessionCalled.fulfill()
        }

        let sessionUUID = UUID()
        XCTAssertEqual(handler.sessionState(uuid: sessionUUID), .stopped)

        handler.beginBillingSession(for: .activeGuidance, uuid: sessionUUID)

        DispatchQueue.main.async() { [unowned self] in
            handler.stopBillingSession(with: sessionUUID)
        }

        waitForExpectations(timeout: 1, handler: nil)
        XCTAssertEqual(handler.sessionState(uuid: sessionUUID), .stopped)

        billingService.assertEvents([
            .beginBillingSession(.activeGuidance),
            .stopBillingSession(.activeGuidance),
        ])
    }

    func testSessionStart() {
        let expectedSessionType = BillingHandler.SessionType.activeGuidance
        let billingEventTriggered = expectation(description: "Billing event triggered")
        let beginSessionTriggered = expectation(description: "Beging session triggered")
        billingService.onStopBillingSession = { _ in
            XCTFail("Cancel shouldn't be called")
        }
        billingService.onBeginBillingSession = { sessionType, _ in
            beginSessionTriggered.fulfill()
            XCTAssertEqual(sessionType, expectedSessionType)
        }

        billingService.onTriggerBillingEvent = { _ in
            billingEventTriggered.fulfill()
        }

        let sessionUUID = UUID()
        handler.beginBillingSession(for: expectedSessionType, uuid: sessionUUID)
        XCTAssertEqual(handler.sessionState(uuid: sessionUUID), .running)
        waitForExpectations(timeout: 1, handler: nil)

        billingService.assertEvents([
            .beginBillingSession(expectedSessionType),
        ])
    }

    func testSessionPause() {
        let sessionStarted = expectation(description: "Session started")
        let sessionPaused = expectation(description: "Session paused")
        billingService.onBeginBillingSession = { _, _ in
            sessionStarted.fulfill()
        }
        billingService.onPauseBillingSession = { _ in
            sessionPaused.fulfill()
        }

        let sessionUUID = UUID()
        handler.beginBillingSession(for: .freeDrive, uuid: sessionUUID)
        handler.pauseBillingSession(with: sessionUUID)
        waitForExpectations(timeout: 1, handler: nil)
        XCTAssertEqual(handler.sessionState(uuid: sessionUUID), .paused)
        let billingSessionResumed = expectation(description: "Billing session resumed")
        billingService.onResumeBillingSession = { _, _ in
            billingSessionResumed.fulfill()
        }

        handler.resumeBillingSession(with: sessionUUID)
        waitForExpectations(timeout: 1, handler: nil)
        XCTAssertEqual(handler.sessionState(uuid: sessionUUID), .running)


        billingService.assertEvents([
            .beginBillingSession(.freeDrive),
            .pauseBillingSession(.freeDrive),
            .resumeBillingSession(.freeDrive),
        ])
    }

    func testSessionResumeFailed() {
        let expectedSessionType = BillingHandler.SessionType.activeGuidance
        let sessionStarted = expectation(description: "Session started")
        sessionStarted.expectedFulfillmentCount = 2
        billingService.onBeginBillingSession = { sessionType, _ in
            sessionStarted.fulfill()
            XCTAssertEqual(sessionType, expectedSessionType)
        }
        billingService.onResumeBillingSession = { _, onError in
            DispatchQueue.global().async {
                onError(.resumeFailed)
            }
        }

        let sessionUUID = UUID()
        handler.beginBillingSession(for: expectedSessionType, uuid: sessionUUID)
        handler.pauseBillingSession(with: sessionUUID)
        handler.resumeBillingSession(with: sessionUUID)
        waitForExpectations(timeout: 1, handler: nil)
        XCTAssertEqual(handler.sessionState(uuid: sessionUUID), .running)


        billingService.assertEvents([
            .beginBillingSession(expectedSessionType),
            .pauseBillingSession(expectedSessionType),
            .resumeBillingSession(expectedSessionType),
            .beginBillingSession(expectedSessionType),
        ])
    }

    func testSessionBeginFailed() {
        let sessionFailed = expectation(description: "Session Failed")
        billingService.onBeginBillingSession = { _, onError in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                onError(.unknown)
                sessionFailed.fulfill()
            }
        }
        let sessionUUID = UUID()
        handler.beginBillingSession(for: .activeGuidance, uuid: sessionUUID)
        XCTAssertEqual(handler.sessionState(uuid: sessionUUID), .running)
        waitForExpectations(timeout: 3, handler: nil)
        XCTAssertEqual(handler.sessionState(uuid: sessionUUID), .stopped)

        billingService.assertEvents([
            .beginBillingSession(.activeGuidance),
        ])
    }

    func testFailedMauBillingDoNotStopSession() {
        let billingEventTriggered = expectation(description: "Billing event triggered")
        let beginSessionTriggered = expectation(description: "Begin session triggered")
        billingService.onTriggerBillingEvent = { onError in
            DispatchQueue.global().async {
                onError(.tokenValidationFailed)
                billingEventTriggered.fulfill()
            }
        }
        billingService.onBeginBillingSession = { _, _ in
            beginSessionTriggered.fulfill()
        }
        let sessionUUID = UUID()
        handler.beginBillingSession(for: .activeGuidance, uuid: sessionUUID)
        waitForExpectations(timeout: 2, handler: nil)
        XCTAssertEqual(handler.sessionState(uuid: sessionUUID), .running)

        billingService.assertEvents([
            .beginBillingSession(.activeGuidance),
        ])
    }

    /// If two sessions starts, one after another, and then the first one stopped, the billing session should continue.
    func testTwoSessionsWithOneStopped() {
        let finished = expectation(description: "Finished")
        let queue = DispatchQueue(label: "")
        queue.async {
            self.handler.beginBillingSession(for: .freeDrive, uuid: UUID())
        }
        queue.async {
            let sessionUUID = UUID()

            self.handler.beginBillingSession(for: .activeGuidance, uuid: sessionUUID)
            queue.async {
                self.handler.stopBillingSession(with: sessionUUID)
                finished.fulfill()
            }
        }
        waitForExpectations(timeout: 1, handler: nil)

        billingService.assertEvents([
            .beginBillingSession(.freeDrive),
            .beginBillingSession(.activeGuidance),
            .stopBillingSession(.activeGuidance)
        ])
    }

    func testTwoSessionsWithResumeFailed() {
        let sessionStarted = expectation(description: "Session started")
        let sessionStopped = expectation(description: "Session stopped")
        sessionStarted.expectedFulfillmentCount = 3
        sessionStopped.expectedFulfillmentCount = 2
        billingService.onBeginBillingSession = { _, onError in
            sessionStarted.fulfill()
        }
        billingService.onStopBillingSession = { _ in
            sessionStopped.fulfill()
        }
        billingService.onResumeBillingSession = { _, onError in
            onError(.resumeFailed)
        }
        let queue = DispatchQueue(label: "")
        let freeDriveSessionUUID = UUID()
        let activeGuidanceSessionUUID = UUID()

        queue.async {
            self.handler.beginBillingSession(for: .freeDrive, uuid: freeDriveSessionUUID)
        }
        queue.async {
            self.handler.beginBillingSession(for: .activeGuidance, uuid: activeGuidanceSessionUUID)
        }
        queue.async {
            self.handler.pauseBillingSession(with: activeGuidanceSessionUUID)
        }
        queue.async {
            self.handler.resumeBillingSession(with: activeGuidanceSessionUUID)
        }
        queue.async {
            self.handler.stopBillingSession(with: activeGuidanceSessionUUID)
        }
        queue.async {
            self.handler.stopBillingSession(with: freeDriveSessionUUID)
        }
        waitForExpectations(timeout: 5, handler: nil)
        billingService.assertEvents([
            .beginBillingSession(.freeDrive),
            .beginBillingSession(.activeGuidance),
            .pauseBillingSession(.activeGuidance),
            .resumeBillingSession(.activeGuidance),
            .beginBillingSession(.activeGuidance),
            .stopBillingSession(.activeGuidance),
            .stopBillingSession(.freeDrive),
        ])
    }

    func testPausedPassiveLocationManagerDoNotUpdateStatus() {
        class UpdatesSpy: PassiveLocationManagerDelegate {
            var onProgressUpdate: (() -> Void)?

            func passiveLocationManager(_ manager: PassiveLocationManager,
                                        didUpdateLocation location: CLLocation,
                                        rawLocation: CLLocation) {
                onProgressUpdate?()
            }

            func passiveLocationManagerDidChangeAuthorization(_ manager: PassiveLocationManager) {}
            func passiveLocationManager(_ manager: PassiveLocationManager, didUpdateHeading newHeading: CLHeading) {}
            func passiveLocationManager(_ manager: PassiveLocationManager, didFailWithError error: Error) {}
        }

        let updatesSpy = UpdatesSpy()
        updatesSpy.onProgressUpdate = {
            XCTFail("Updated on paused session isn't allowed")
        }

        let locations = Array<CLLocation>.locations(from: "sthlm-double-back-replay")
        let locationManager = ReplayLocationManager(locations: locations)
        locationManager.startDate = Date()

        let passiveLocationManager = PassiveLocationManager(directions: DirectionsSpy(),
                                                            systemLocationManager: locationManager)

        locationManager.delegate = passiveLocationManager
        passiveLocationManager.delegate = updatesSpy
        passiveLocationManager.pauseTripSession()
        locationManager.tick()

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        billingServiceMock.assertEvents([
            .beginBillingSession(.freeDrive),
            .pauseBillingSession(.freeDrive)
        ])

        XCTAssertNil(passiveLocationManager.rawLocation, "Location updates should be blocked")

        passiveLocationManager.resumeTripSession()
        locationManager.tick()
        XCTAssertNotNil(passiveLocationManager.rawLocation)
    }

    func testTokens() {
        let freeDriveSessionUUID = UUID()
        let activeGuidanceSessionUUID = UUID()
        handler.beginBillingSession(for: .freeDrive, uuid: freeDriveSessionUUID)
        XCTAssertEqual(handler.serviceSkuToken, freeRideToken)
        handler.beginBillingSession(for: .activeGuidance, uuid: activeGuidanceSessionUUID)
        XCTAssertEqual(handler.serviceSkuToken, activeGuidanceToken)
        handler.pauseBillingSession(with: activeGuidanceSessionUUID)
        XCTAssertEqual(handler.serviceSkuToken, freeRideToken)
        handler.pauseBillingSession(with: freeDriveSessionUUID)
        XCTAssertEqual(handler.serviceSkuToken, "")
        handler.resumeBillingSession(with: freeDriveSessionUUID)
        XCTAssertEqual(handler.serviceSkuToken, freeRideToken)
        handler.resumeBillingSession(with: activeGuidanceSessionUUID)
        XCTAssertEqual(handler.serviceSkuToken, activeGuidanceToken)
        handler.stopBillingSession(with: activeGuidanceSessionUUID)
        XCTAssertEqual(handler.serviceSkuToken, freeRideToken)
        handler.stopBillingSession(with: freeDriveSessionUUID)
        XCTAssertEqual(handler.serviceSkuToken, "")
    }

    func testStartingFreeRideAfterActiveGuidance() {
        handler.beginBillingSession(for: .activeGuidance, uuid: .init())
        XCTAssertEqual(handler.serviceSkuToken, activeGuidanceToken)
        handler.beginBillingSession(for: .freeDrive, uuid: .init())
        XCTAssertEqual(handler.serviceSkuToken, activeGuidanceToken)
    }

    func testSessionStoppedForNonExistingUUID() {
        XCTAssertEqual(billingService.getSessionStatus(for: .activeGuidance), .stopped)
        XCTAssertEqual(handler.sessionState(uuid: UUID()), .stopped)
    }

    func testOneBillingSessionForTwoSameRideSession() {
        let session1UUID = UUID()
        let session2UUID = UUID()
        handler.beginBillingSession(for: .activeGuidance, uuid: session1UUID)
        handler.beginBillingSession(for: .activeGuidance, uuid: session2UUID)
        XCTAssertEqual(billingService.getSessionStatus(for: .activeGuidance), .running)
        handler.stopBillingSession(with: session1UUID)
        XCTAssertEqual(handler.sessionState(uuid: session1UUID), .stopped)
        XCTAssertEqual(handler.sessionState(uuid: session2UUID), .running)
        XCTAssertEqual(billingService.getSessionStatus(for: .activeGuidance), .running)
        handler.stopBillingSession(with: session2UUID)
        XCTAssertEqual(handler.sessionState(uuid: session2UUID), .stopped)
        XCTAssertEqual(billingService.getSessionStatus(for: .activeGuidance), .stopped)

        billingService.assertEvents([
            .beginBillingSession(.activeGuidance),
            .stopBillingSession(.activeGuidance)
        ])
    }

    func testTwoBillingSessionForTwoSameRideSession() {
        let activeGuidanceSession1UUID = UUID()
        let activeGuidanceSession2UUID = UUID()
        let freeRideSession1UUID = UUID()
        let freeRideSession2UUID = UUID()

        handler.beginBillingSession(for: .activeGuidance, uuid: activeGuidanceSession1UUID)
        handler.beginBillingSession(for: .activeGuidance, uuid: activeGuidanceSession2UUID)
        handler.beginBillingSession(for: .freeDrive, uuid: freeRideSession1UUID)
        handler.beginBillingSession(for: .freeDrive, uuid: freeRideSession2UUID)
        handler.stopBillingSession(with: activeGuidanceSession1UUID)
        handler.stopBillingSession(with: activeGuidanceSession2UUID)
        handler.stopBillingSession(with: freeRideSession2UUID)
        handler.stopBillingSession(with: freeRideSession1UUID)

        billingService.assertEvents([
            .beginBillingSession(.activeGuidance),
            .beginBillingSession(.freeDrive),
            .stopBillingSession(.activeGuidance),
            .stopBillingSession(.freeDrive)
        ])
    }

    /// A test case with quite complex configuration
    func testComplexUsecase() {
        let activeGuidanceSession1UUID = UUID()
        let activeGuidanceSession2UUID = UUID()
        let freeRideSession1UUID = UUID()
        let freeRideSession2UUID = UUID()

        handler.beginBillingSession(for: .activeGuidance, uuid: activeGuidanceSession1UUID)
        handler.beginBillingSession(for: .freeDrive, uuid: freeRideSession1UUID)
        handler.beginBillingSession(for: .activeGuidance, uuid: activeGuidanceSession2UUID)
        handler.beginBillingSession(for: .freeDrive, uuid: freeRideSession2UUID)
        handler.pauseBillingSession(with: freeRideSession1UUID)
        handler.pauseBillingSession(with: activeGuidanceSession1UUID)
        handler.resumeBillingSession(with: activeGuidanceSession1UUID)
        handler.resumeBillingSession(with: freeRideSession1UUID)
        handler.pauseBillingSession(with: freeRideSession1UUID)
        handler.pauseBillingSession(with: freeRideSession2UUID)
        handler.resumeBillingSession(with: freeRideSession1UUID)
        handler.stopBillingSession(with: activeGuidanceSession1UUID)
        handler.stopBillingSession(with: activeGuidanceSession2UUID)
        handler.pauseBillingSession(with: freeRideSession1UUID)
        handler.pauseBillingSession(with: freeRideSession2UUID)
        handler.stopBillingSession(with: freeRideSession2UUID)
        handler.stopBillingSession(with: freeRideSession1UUID)

        billingService.assertEvents([
            .beginBillingSession(.activeGuidance),
            .beginBillingSession(.freeDrive),
            .pauseBillingSession(.freeDrive),
            .resumeBillingSession(.freeDrive),
            .stopBillingSession(.activeGuidance),
            .pauseBillingSession(.freeDrive),
            .stopBillingSession(.freeDrive),
        ])
    }

    func testRouteChangeCloseToOriginal() {
        runRouteChangeTest(
            initialRouteWaypoints: [
                CLLocationCoordinate2D(latitude: 59.337928, longitude: 18.076841),
                CLLocationCoordinate2D(latitude: 59.347928, longitude: 18.086841),
            ],
            newRouteWaypoints: [
                CLLocationCoordinate2D(latitude: 59.337928, longitude: 18.076841),
                CLLocationCoordinate2D(latitude: 59.347929, longitude: 18.086842),
            ],
            expectedEvents: [
                .beginBillingSession(.activeGuidance),
            ]
        )
    }

    func testRouteChangeDifferentToOriginal() {
        runRouteChangeTest(
            initialRouteWaypoints: [
                CLLocationCoordinate2D(latitude: 59.337928, longitude: 18.076841),
                CLLocationCoordinate2D(latitude: 59.347928, longitude: 18.086841),
            ],
            newRouteWaypoints: [
                CLLocationCoordinate2D(latitude: 59.337928, longitude: 18.076841),
                CLLocationCoordinate2D(latitude: 60.347929, longitude: 18.086841),
            ],
            expectedEvents: [
                .beginBillingSession(.activeGuidance),
                .stopBillingSession(.activeGuidance),
                .beginBillingSession(.activeGuidance),
            ]
        )
    }

    func testRouteChangeCloseToOriginalMultileg() {
        runRouteChangeTest(
            initialRouteWaypoints: [
                CLLocationCoordinate2D(latitude: 59.337928, longitude: 18.076841),
                CLLocationCoordinate2D(latitude: 59.347928, longitude: 18.086841),
                CLLocationCoordinate2D(latitude: 59.357928, longitude: 18.086841),
                CLLocationCoordinate2D(latitude: 59.367928, longitude: 18.086841),
            ],
            newRouteWaypoints: [
                CLLocationCoordinate2D(latitude: 59.337928, longitude: 18.076841),
                CLLocationCoordinate2D(latitude: 59.347929, longitude: 18.086841),
                CLLocationCoordinate2D(latitude: 59.357929, longitude: 18.086841),
                CLLocationCoordinate2D(latitude: 59.367929, longitude: 18.086841),
            ],
            expectedEvents: [
                .beginBillingSession(.activeGuidance),
            ]
        )
    }

    func testPauseSessionWithStoppingSimilarOne() {
        let freeRideSession1UUID = UUID()
        let freeRideSession2UUID = UUID()

        handler.beginBillingSession(for: .freeDrive, uuid: freeRideSession1UUID)
        handler.beginBillingSession(for: .freeDrive, uuid: freeRideSession2UUID)
        handler.pauseBillingSession(with: freeRideSession1UUID)
        handler.stopBillingSession(with: freeRideSession2UUID)

        billingService.assertEvents([
            .beginBillingSession(.freeDrive),
            .pauseBillingSession(.freeDrive),
        ])
    }

    func testBeginSessionWithPausedSimilarOne() {
        let freeRideSession1UUID = UUID()
        let freeRideSession2UUID = UUID()

        handler.beginBillingSession(for: .freeDrive, uuid: freeRideSession1UUID)
        handler.pauseBillingSession(with: freeRideSession1UUID)
        handler.beginBillingSession(for: .freeDrive, uuid: freeRideSession2UUID)

        billingService.assertEvents([
            .beginBillingSession(.freeDrive),
            .pauseBillingSession(.freeDrive),
            .resumeBillingSession(.freeDrive)
        ])
    }

    func testBeginSessionWithPausedSimilarOneButFailed() {
        let freeRideSession1UUID = UUID()
        let freeRideSession2UUID = UUID()

        let resumeFailedCalled = expectation(description: "Resume Failed Called")
        billingService.onResumeBillingSession = { _, onError in
            DispatchQueue.global().async {
                onError(.resumeFailed)
                DispatchQueue.global().async {
                    resumeFailedCalled.fulfill()
                }
            }
        }

        handler.beginBillingSession(for: .freeDrive, uuid: freeRideSession1UUID)
        handler.pauseBillingSession(with: freeRideSession1UUID)
        handler.beginBillingSession(for: .freeDrive, uuid: freeRideSession2UUID)

        waitForExpectations(timeout: 1, handler: nil)

        billingService.assertEvents([
            .beginBillingSession(.freeDrive),
            .pauseBillingSession(.freeDrive),
            .resumeBillingSession(.freeDrive),
            .beginBillingSession(.freeDrive),
        ])
    }


    private func runRouteChangeTest(initialRouteWaypoints: [CLLocationCoordinate2D],
                                    newRouteWaypoints: [CLLocationCoordinate2D],
                                    expectedEvents: [BillingServiceMock.Event]) {
        precondition(initialRouteWaypoints.count % 2 == 0)

        final class DataSource: RouterDataSource {
            var locationManagerType: NavigationLocationManager.Type {
                NavigationLocationManager.self
            }
        }

        let (initialRouteResponse, _) = Fixture.route(waypoints: initialRouteWaypoints)
        let (newRouteResponse, _) = Fixture.route(waypoints: newRouteWaypoints)

        let dataSource = DataSource()
        let routeController = RouteController(alongRouteAtIndex: 0,
                                              in: initialRouteResponse,
                                              options: NavigationRouteOptions(coordinates: initialRouteWaypoints),
                                              dataSource: dataSource)

        let routeUpdated = expectation(description: "Route updated")
        routeController.updateRoute(with: IndexedRouteResponse(routeResponse: newRouteResponse,
                                                               routeIndex: 0),
                                    routeOptions: NavigationRouteOptions(coordinates: newRouteWaypoints)) { success in
            XCTAssertTrue(success)
            routeUpdated.fulfill()
        }
        wait(for: [routeUpdated], timeout: 10)
        billingServiceMock.assertEvents(expectedEvents)
    }

    func testServiceAccessToken() {
        let expectedAccessToken = UUID().uuidString
        billingServiceMock.accessToken = expectedAccessToken
        XCTAssertEqual(Accounts.serviceAccessToken, expectedAccessToken)
    }

    func testForceStartNewBillingSession() {
        let sessionUuid = UUID()
        handler.beginBillingSession(for: .activeGuidance, uuid: sessionUuid)
        handler.beginNewBillingSessionIfRunning(with: sessionUuid)
        
        billingService.assertEvents([
            .beginBillingSession(.activeGuidance),
            .beginBillingSession(.activeGuidance),
        ])
    }

    func testForceStartNewBillingSessionOnPausedSession() {
        let sessionUuid = UUID()
        handler.beginBillingSession(for: .activeGuidance, uuid: sessionUuid)
        handler.pauseBillingSession(with: sessionUuid)
        handler.beginNewBillingSessionIfRunning(with: sessionUuid)

        billingService.assertEvents([
            .beginBillingSession(.activeGuidance),
            .pauseBillingSession(.activeGuidance)
        ])
    }

    func testForceStartNewBillingSessionOnNonExistentSession() {
        let sessionUuid = UUID()
        handler.beginNewBillingSessionIfRunning(with: sessionUuid)

        billingService.assertEvents([
        ])
    }

    func testTripPerWaypoint() {
        let legsCount = 10
        autoreleasepool {
            let origin = CLLocationCoordinate2D(latitude: 0, longitude: 0)
            let destination = CLLocationCoordinate2D(latitude: 0.001, longitude: 0.001)

            let routeResponse = Fixture.route(between: origin, and: destination, legsCount: legsCount).response

            let replyLocations = Fixture.generateCoordinates(between: origin, and: destination, count: 1000)
                .map { CLLocation(coordinate: $0) }
                .shiftedToPresent()

            let directions = DirectionsSpy()

            let navOptions = NavigationRouteOptions(coordinates: [origin, destination])
            let routeController = RouteController(alongRouteAtIndex: 0,
                                                  in: routeResponse,
                                                  options: navOptions,
                                                  directions: directions,
                                                  dataSource: self)

            let routerDelegateSpy = RouterDelegateSpy()
            routeController.delegate = routerDelegateSpy

            let locationManager = ReplayLocationManager(locations: replyLocations)
            locationManager.startDate = Date()
            locationManager.delegate = routeController

            let arrivedAtWaypoint = expectation(description: "Arrive at waypoint")
            arrivedAtWaypoint.expectedFulfillmentCount = legsCount
            routerDelegateSpy.onDidArriveAt = { waypoint in
                arrivedAtWaypoint.fulfill()
                return true
            }

            let speedMultiplier: TimeInterval = 100
            locationManager.speedMultiplier = speedMultiplier
            locationManager.startUpdatingLocation()
            waitForExpectations(timeout: TimeInterval(replyLocations.count) / speedMultiplier + 1, handler: nil)
        }

        var expectedEvents: [BillingServiceMock.Event] = []
        for _ in 0..<legsCount {
            expectedEvents.append(.beginBillingSession(.activeGuidance))
        }
        expectedEvents.append(.stopBillingSession(.activeGuidance))
        billingServiceMock.assertEvents(expectedEvents)
    }
}

extension BillingHandlerUnitTests: RouterDataSource {
    var locationManagerType: NavigationLocationManager.Type {
        return NavigationLocationManager.self
    }
}
