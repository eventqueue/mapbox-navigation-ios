import XCTest
import MapboxDirections
import Turf
import MapboxMobileEvents
import os.log
@testable import TestHelper
@testable import MapboxCoreNavigation

fileprivate let mbTestHeading: CLLocationDirection = 50

// minimum distance threshold between two locations (in meters)
fileprivate let distanceThreshold: CLLocationDistance = 2

// minimum threshold for both latitude and longitude between two coordinates
fileprivate let coordinateThreshold: CLLocationDistance = 0.0005

class NavigationServiceTests: TestCase {
    var eventsManagerSpy: NavigationEventsManagerSpy!
    let directionsClientSpy = DirectionsSpy()
    let delegate = NavigationServiceDelegateSpy()

    typealias RouteLocations = (firstLocation: CLLocation, penultimateLocation: CLLocation, lastLocation: CLLocation)

    var dependencies: (navigationService: NavigationService, routeLocations: RouteLocations)!
    
    func createDependencies(locationSource: NavigationLocationManager? = nil) -> (navigationService: NavigationService, routeLocations: RouteLocations) {
        let navigationService = MapboxNavigationService(routeResponse: initialRouteResponse,
                                                        routeIndex: 0,
                                                        routeOptions: routeOptions,
                                                        directions: directionsClientSpy,
                                                        locationSource: locationSource,
                                                        eventsManagerType: NavigationEventsManagerSpy.self,
                                                        simulating: .never)
        navigationService.delegate = delegate

        let legProgress: RouteLegProgress = navigationService.router.routeProgress.currentLegProgress

        let firstCoord = navigationService.router.routeProgress.nearbyShape.coordinates.first!
        let firstLocation = CLLocation(coordinate: firstCoord, altitude: 5, horizontalAccuracy: 10, verticalAccuracy: 5, course: 20, speed: 4, timestamp: Date())

        let penultimateCoord = legProgress.remainingSteps[4].shape!.coordinates.first!
        let penultimateLocation = CLLocation(coordinate: penultimateCoord, altitude: 5, horizontalAccuracy: 10, verticalAccuracy: 5, course: 20, speed: 4, timestamp: Date())

        let lastCoord = legProgress.remainingSteps.last!.shape!.coordinates.first!
        let lastLocation = CLLocation(coordinate: lastCoord, altitude: 5, horizontalAccuracy: 10, verticalAccuracy: 5, course: 20, speed: 4, timestamp: Date())

        let routeLocations = RouteLocations(firstLocation, penultimateLocation, lastLocation)

        return (navigationService: navigationService, routeLocations: routeLocations)
    }

    let initialRouteResponse = Fixture.routeResponse(from: jsonFileName, options: routeOptions)

    let alternateRouteResponse = Fixture.routeResponse(from: jsonFileName, options: routeOptions)
    let alternateRoute = Fixture.route(from: jsonFileName, options: routeOptions)

    override func setUp() {
        super.setUp()

        directionsClientSpy.reset()
        delegate.reset()
    }
    
    override func tearDown() {
        super.tearDown()
        dependencies = nil
    }

    func testDefaultUserInterfaceUsage() {
        dependencies = createDependencies()
        let usesDefaultUserInterface = dependencies.navigationService.eventsManager.usesDefaultUserInterface
        
        // When building via Xcode when using SPM `MapboxNavigation` bundle will be present.
        if let _ = Bundle.mapboxNavigationIfInstalled {
            // Even though `MapboxCoreNavigationTests` does not directly link `MapboxNavigation`, it uses
            // `TestHelper`, which in turn uses `MapboxNavigation`. This means that its bundle will be present
            // in `MapboxCoreNavigationTests.xctest`.
            XCTAssertTrue(usesDefaultUserInterface, "Due to indirect linkage, `MapboxNavigation` will be linked to `MapboxCoreNavigationTests`.")
        } else {
            XCTAssertFalse(usesDefaultUserInterface, "MapboxCoreNavigationTests shouldn't have an implicit dependency on MapboxNavigation due to removing the Example application target as the test host.")
        }
    }
    
    func testUserIsOnRoute() {
        dependencies = createDependencies()

        let navigation = dependencies.navigationService
        let firstLocation = dependencies.routeLocations.firstLocation

        navigation.locationManager!(navigation.locationManager, didUpdateLocations: [firstLocation])
        
        waitForNavNativeCallbacks()
        
        XCTAssertTrue(navigation.router.userIsOnRoute(firstLocation), "User should be on route")
    }

    func testUserIsOffRoute() {
        dependencies = createDependencies()

        let navigation = dependencies.navigationService
        let route = navigation.route
        
        // Create list of 3 coordinates which are located on actual route
        let coordinatesOnRoute = route.shape!.coordinates.prefix(3)
        let now = Date()
        let locationsOnRoute = coordinatesOnRoute.enumerated().map {
            CLLocation(coordinate: $0.element,
                       altitude: -1,
                       horizontalAccuracy: 10,
                       verticalAccuracy: -1,
                       course: -1,
                       speed: 10,
                       timestamp: now + $0.offset)
        }
        
        // Iterate over each location on the route and simulate location update
        locationsOnRoute.forEach {
            navigation.router.locationManager!(navigation.locationManager, didUpdateLocations: [$0])
            
            waitForNavNativeCallbacks()
            
            // Verify whether current location is located on the route
            XCTAssertTrue(navigation.router.userIsOnRoute($0), "User should be on the route")
        }
        
        // Create list of 3 coordinates: all coordinates have distance component slightly changed, which means that they're off the route
        let coordinatesOffRoute: [CLLocationCoordinate2D] = (0...2).map { _ in locationsOnRoute.first!.coordinate.coordinate(at: 100, facing: 90) }
        let locationsOffRoute = coordinatesOffRoute.enumerated().map {
            CLLocation(coordinate: $0.element,
                       altitude: -1,
                       horizontalAccuracy: 10,
                       verticalAccuracy: -1,
                       course: -1,
                       speed: 10,
                       timestamp: now + locationsOnRoute.count + $0.offset)
        }
        
        // Iterate over the list of locations which are off the route and verify whether all locations except first one are off the route.
        // Even though first location is off the route as per navigation native logic it sometimes can return tracking route state
        // even if location is visually off-route.
        locationsOffRoute.enumerated().forEach {
            navigation.router.locationManager!(navigation.locationManager, didUpdateLocations: [$0.element])
            
            waitForNavNativeCallbacks()
            
            if ($0.offset == 0) {
                XCTAssertTrue(navigation.router.userIsOnRoute($0.element), "For the first coordinate user is still on the route")
            } else {
                XCTAssertFalse(navigation.router.userIsOnRoute($0.element), "User should be off route")
            }
        }
    }

    func testNotReroutingForAllSteps() {
        dependencies = createDependencies()
        
        let navigationService = dependencies.navigationService
        let route = navigationService.route
        
        var offset = 0
        let currentDate = Date()
        
        // Iterate over each step in leg, take all coordinates it contains and create array of `CLLocation`s
        // based on them. Each `CLLocation` must contain `timestamp` property, which is strictly
        // increasing, otherwise Navigator might filter them out.
        route.legs[0].steps.enumerated().forEach {
            guard let stepCoordinates = $0.element.shape?.coordinates else {
                XCTFail("Route shape should be valid.")
                return
            }
            
            var stepLocations: [CLLocation] = []
            for coordinate in stepCoordinates {
                if let lastLocation = stepLocations.last,
                   lastLocation.timestamp >= (currentDate + offset) {
                    XCTFail("Previous timestamp should not be equal to, or higher than the current one.")
                    return
                }
                
                stepLocations.append(CLLocation(coordinate: coordinate,
                                                altitude: -1,
                                                horizontalAccuracy: 10,
                                                verticalAccuracy: -1,
                                                course: -1,
                                                speed: 10,
                                                timestamp: currentDate + offset))
                
                offset += 1
            }
            
            stepLocations.forEach {
                navigationService.router.locationManager?(navigationService.locationManager, didUpdateLocations: [$0])
            }
            
            waitForNavNativeCallbacks()
            
            guard let lastLocation = stepLocations.last else {
                XCTFail("Last location should be valid.")
                return
            }
            
            XCTAssertTrue(navigationService.router.userIsOnRoute(lastLocation), "User should be on route")
        }
    }

    func testSnappedAtEndOfStepLocationWhenMovingSlowly() {
        dependencies = createDependencies()

        let navigation = dependencies.navigationService
        let firstLocation = dependencies.routeLocations.firstLocation

        navigation.locationManager!(navigation.locationManager, didUpdateLocations: [firstLocation])
        
        // Check whether snapped location is within allowed threshold
        XCTAssertEqual(navigation.router.location!.coordinate.latitude, firstLocation.coordinate.latitude, accuracy: coordinateThreshold, "Latitudes should be almost equal")
        XCTAssertEqual(navigation.router.location!.coordinate.longitude, firstLocation.coordinate.longitude, accuracy: coordinateThreshold, "Longitudes should be almost equal")

        // Check whether distance (in meters) between snapped location and first location on a route is within allowed threshold
        var distance = navigation.router.location!.distance(from: firstLocation)
        XCTAssertLessThan(distance, distanceThreshold)

        let firstCoordinateOnUpcomingStep = navigation.router.routeProgress.currentLegProgress.upcomingStep!.shape!.coordinates.first!
        let firstLocationOnNextStepWithNoSpeed = CLLocation(coordinate: firstCoordinateOnUpcomingStep,
                                                            altitude: 0,
                                                            horizontalAccuracy: 10,
                                                            verticalAccuracy: 10,
                                                            course: 10,
                                                            speed: 0,
                                                            timestamp: Date())

        navigation.locationManager!(navigation.locationManager, didUpdateLocations: [firstLocationOnNextStepWithNoSpeed])
        
        waitForNavNativeCallbacks()
        
        // When user is not moving (location is changed to first one in upcoming step, but neither speed nor timestamp were changed)
        // navigation native will snap to current location in current step
        XCTAssertEqual(navigation.router.location!.coordinate.latitude, firstLocation.coordinate.latitude, accuracy: coordinateThreshold, "Latitudes should be almost equal")
        XCTAssertEqual(navigation.router.location!.coordinate.longitude, firstLocation.coordinate.longitude, accuracy: coordinateThreshold, "Longitudes should be almost equal")
        distance = navigation.router.location!.distance(from: firstLocation)
        XCTAssertLessThan(distance, distanceThreshold)
        
        let firstLocationOnNextStepWithSpeed = CLLocation(coordinate: firstCoordinateOnUpcomingStep,
                                                          altitude: 0,
                                                          horizontalAccuracy: 10,
                                                          verticalAccuracy: 10,
                                                          course: 10,
                                                          speed: 5,
                                                          timestamp: Date() + 5)
        navigation.locationManager!(navigation.locationManager, didUpdateLocations: [firstLocationOnNextStepWithSpeed])
        
        waitForNavNativeCallbacks()

        // User is snapped to upcoming step when moving
        XCTAssertEqual(navigation.router.location!.coordinate.latitude, firstCoordinateOnUpcomingStep.latitude, accuracy: coordinateThreshold, "Latitudes should be almost equal")
        XCTAssertEqual(navigation.router.location!.coordinate.longitude, firstCoordinateOnUpcomingStep.longitude, accuracy: coordinateThreshold, "Longitudes should be almost equal")
        distance = navigation.router.location!.distance(from: firstLocationOnNextStepWithSpeed)
        XCTAssertLessThan(distance, distanceThreshold)
    }

    func testSnappedAtEndOfStepLocationWhenCourseIsSimilar() {
        dependencies = createDependencies()

        let navigation = dependencies.navigationService
        let firstLocation = dependencies.routeLocations.firstLocation

        navigation.locationManager!(navigation.locationManager, didUpdateLocations: [firstLocation])
        
        // Check whether snapped location is within allowed threshold
        XCTAssertEqual(navigation.router.location!.coordinate.latitude, firstLocation.coordinate.latitude, accuracy: coordinateThreshold, "Latitudes should be almost equal")
        XCTAssertEqual(navigation.router.location!.coordinate.longitude, firstLocation.coordinate.longitude, accuracy: coordinateThreshold, "Longitudes should be almost equal")
        
        // Check whether distance (in meters) between snapped location and first location on a route is within allowed threshold
        var distance = navigation.router.location!.distance(from: firstLocation)
        XCTAssertLessThan(distance, distanceThreshold)
        
        let firstCoordinateOnUpcomingStep = navigation.router.routeProgress.currentLegProgress.upcomingStep!.shape!.coordinates.first!

        let finalHeading = navigation.router.routeProgress.currentLegProgress.upcomingStep!.finalHeading!
        let firstLocationOnNextStepWithDifferentCourse = CLLocation(coordinate: firstCoordinateOnUpcomingStep,
                                                                    altitude: 0,
                                                                    horizontalAccuracy: 30,
                                                                    verticalAccuracy: 10,
                                                                    course: (finalHeading + 180).truncatingRemainder(dividingBy: 360),
                                                                    speed: 5,
                                                                    timestamp: Date() + 5)

        navigation.locationManager!(navigation.locationManager, didUpdateLocations: [firstLocationOnNextStepWithDifferentCourse])

        let lastCoordinateOnCurrentStep = navigation.router.routeProgress.currentLegProgress.currentStep.shape!.coordinates.last!
        
        waitForNavNativeCallbacks()

        // When user's course is dissimilar from the finalHeading, they should not snap to upcoming step
        XCTAssertEqual(navigation.router.location!.coordinate.latitude, lastCoordinateOnCurrentStep.latitude, accuracy: coordinateThreshold, "Latitudes should be almost equal")
        XCTAssertEqual(navigation.router.location!.coordinate.longitude, lastCoordinateOnCurrentStep.longitude, accuracy: coordinateThreshold, "Longitudes should be almost equal")
        distance = navigation.router.location!.distance(from: CLLocation(latitude: lastCoordinateOnCurrentStep.latitude, longitude: lastCoordinateOnCurrentStep.longitude))
        XCTAssertLessThan(distance, distanceThreshold)
        
        let firstLocationOnNextStepWithCorrectCourse = CLLocation(coordinate: firstCoordinateOnUpcomingStep,
                                                                  altitude: 0,
                                                                  horizontalAccuracy: 30,
                                                                  verticalAccuracy: 10,
                                                                  course: finalHeading,
                                                                  speed: 0,
                                                                  timestamp: Date())
        navigation.locationManager!(navigation.locationManager, didUpdateLocations: [firstLocationOnNextStepWithCorrectCourse])
        
        // User is snapped to upcoming step when their course is similar to the final heading
        XCTAssertEqual(navigation.router.location!.coordinate.latitude, firstCoordinateOnUpcomingStep.latitude, accuracy: coordinateThreshold, "Latitudes should be almost equal")
        XCTAssertEqual(navigation.router.location!.coordinate.longitude, firstCoordinateOnUpcomingStep.longitude, accuracy: coordinateThreshold, "Longitudes should be almost equal")
        distance = navigation.router.location!.distance(from: firstLocationOnNextStepWithCorrectCourse)
        XCTAssertLessThan(distance, distanceThreshold)
    }

    func testSnappedLocationForUnqualifiedLocation() {
        dependencies = createDependencies()

        let navigation = dependencies.navigationService
        let firstLocation = dependencies.routeLocations.firstLocation
        navigation.locationManager!(navigation.locationManager, didUpdateLocations: [firstLocation])
        
        // Check whether snapped location is within allowed threshold
        XCTAssertEqual(navigation.router.location!.coordinate.latitude, firstLocation.coordinate.latitude, accuracy: coordinateThreshold, "Latitudes should be almost equal")
        XCTAssertEqual(navigation.router.location!.coordinate.longitude, firstLocation.coordinate.longitude, accuracy: coordinateThreshold, "Longitudes should be almost equal")
        
        // Check whether distance (in meters) between snapped location and first location on a route is within allowed threshold
        var distance = navigation.router.location!.distance(from: firstLocation)
        XCTAssertLessThan(distance, distanceThreshold)

        let futureCoordinate = navigation.router.routeProgress.nearbyShape.coordinateFromStart(distance: 100)!
        let futureInaccurateLocation = CLLocation(coordinate: futureCoordinate,
                                                  altitude: 0,
                                                  horizontalAccuracy: 0,
                                                  verticalAccuracy: 0,
                                                  course: 0,
                                                  speed: 0,
                                                  timestamp: Date() + 5)
        
        navigation.locationManager!(navigation.locationManager, didUpdateLocations: [futureInaccurateLocation])
        
        waitForNavNativeCallbacks()

        // Inaccurate location should still be snapped
        XCTAssertEqual(navigation.router.location!.coordinate.latitude, futureInaccurateLocation.coordinate.latitude, accuracy: coordinateThreshold, "Latitudes should be almost equal")
        XCTAssertEqual(navigation.router.location!.coordinate.longitude, futureInaccurateLocation.coordinate.longitude, accuracy: coordinateThreshold, "Longitudes should be almost equal")
        distance = navigation.router.location!.distance(from: futureInaccurateLocation)
        XCTAssertLessThan(distance, distanceThreshold)
    }

    func testLocationCourseShouldNotChange() {
        // This route is a simple straight line: http://geojson.io/#id=gist:anonymous/64cfb27881afba26e3969d06bacc707c&map=17/37.77717/-122.46484
        let options = NavigationRouteOptions(coordinates: [
            CLLocationCoordinate2D(latitude: 37.77735, longitude: -122.461465),
            CLLocationCoordinate2D(latitude: 37.777016, longitude: -122.468832),
        ])
        let routeResponse = Fixture.routeResponse(from: "straight-line", options: options)
        let navigationService = MapboxNavigationService(routeResponse: routeResponse, routeIndex: 0, routeOptions: options)
        let router = navigationService.router
        let firstCoordinate = router.routeProgress.nearbyShape.coordinates.first!
        let firstLocation = CLLocation(latitude: firstCoordinate.latitude, longitude: firstCoordinate.longitude)
        let coordinateNearStart = router.routeProgress.nearbyShape.coordinateFromStart(distance: 10)!
        
        navigationService.locationManager(navigationService.locationManager, didUpdateLocations: [firstLocation])
        
        // As per navigation native logic location course will be set to the course of the road,
        // so providing locations with different course will not affect anything.
        let directionToStart = coordinateNearStart.direction(to: firstCoordinate)
        let facingTowardsStartLocation = CLLocation(coordinate: coordinateNearStart,
                                                    altitude: 0,
                                                    horizontalAccuracy: 0,
                                                    verticalAccuracy: 0,
                                                    course: directionToStart,
                                                    speed: 0,
                                                    timestamp: Date() + 1.0)
        
        navigationService.locationManager(navigationService.locationManager, didUpdateLocations: [facingTowardsStartLocation])
        
        waitForNavNativeCallbacks()
        
        // Instead of raw course navigator will return interpolated course (course of the road).
        let interpolatedCourse = facingTowardsStartLocation.interpolatedCourse(along: router.routeProgress.nearbyShape)!
        XCTAssertEqual(Int(interpolatedCourse), Int(router.location!.course), "Interpolated course and course provided by navigation native should be almost equal.")
        XCTAssertFalse(facingTowardsStartLocation.shouldSnap(toRouteWith: interpolatedCourse,
                                                             distanceToFirstCoordinateOnLeg: facingTowardsStartLocation.distance(from: firstLocation)), "Should not snap")
    }

    //TODO: Broken by PortableRoutecontroller & MBNavigator -- needs team discussion.
    func x_testLocationShouldUseHeading() {
        dependencies = createDependencies()

        let navigation = dependencies.navigationService
        let firstLocation = dependencies.routeLocations.firstLocation
        navigation.locationManager!(navigation.locationManager, didUpdateLocations: [firstLocation])

        XCTAssertEqual(navigation.router.location!.course, firstLocation.course, "Course should be using course")

        let invalidCourseLocation = CLLocation(coordinate: firstLocation.coordinate, altitude: firstLocation.altitude, horizontalAccuracy: firstLocation.horizontalAccuracy, verticalAccuracy: firstLocation.verticalAccuracy, course: -1, speed: firstLocation.speed, timestamp: firstLocation.timestamp)

        let heading = CLHeading(heading: mbTestHeading, accuracy: 1)!

        navigation.locationManager!(navigation.locationManager, didUpdateLocations: [invalidCourseLocation])
        navigation.locationManager!(navigation.locationManager, didUpdateHeading: heading)

        XCTAssertEqual(navigation.router.location!.course, mbTestHeading, "Course should be using bearing")
    }

    // MARK: - Events & Delegation

    func testTurnstileEventSentUponInitialization() {
        // MARK: it sends a turnstile event upon initialization

        let service = MapboxNavigationService(routeResponse: initialRouteResponse, routeIndex: 0, routeOptions: routeOptions, locationSource: NavigationLocationManager(), eventsManagerType: NavigationEventsManagerSpy.self)
        let eventsManagerSpy = service.eventsManager as! NavigationEventsManagerSpy
        XCTAssertTrue(eventsManagerSpy.hasFlushedEvent(with: MMEEventTypeAppUserTurnstile))
    }

    func testReroutingFromLocationUpdatesSimulatedLocationSource() {
        let navigationService = MapboxNavigationService(routeResponse: initialRouteResponse,
                                                        routeIndex: 0,
                                                        routeOptions: routeOptions,
                                                        eventsManagerType: NavigationEventsManagerSpy.self,
                                                        simulating: .always)
        navigationService.delegate = delegate
        let router = navigationService.router

        navigationService.eventsManager.delaysEventFlushing = false
        navigationService.start()

        let eventsManagerSpy = navigationService.eventsManager as! NavigationEventsManagerSpy
        XCTAssertTrue(eventsManagerSpy.hasFlushedEvent(with: NavigationEventTypeRouteRetrieval))

        let routeUpdated = expectation(description: "Route updated")
        router.updateRoute(with: .init(routeResponse: alternateRouteResponse, routeIndex: 0), routeOptions: nil) {
            success in
            XCTAssertTrue(success)
            routeUpdated.fulfill()
        }
        wait(for: [routeUpdated], timeout: 5)

        let simulatedLocationManager = navigationService.locationManager as! SimulatedLocationManager

        XCTAssert(simulatedLocationManager.route == alternateRoute,
                  "Simulated Location Manager should be updated with new route progress model")
    }

    func testReroutingFromALocationSendsEvents() {
        dependencies = createDependencies()

        let navigationService = dependencies.navigationService
        let router = navigationService.router
        let testLocation = dependencies.routeLocations.firstLocation

        navigationService.eventsManager.delaysEventFlushing = false

        let willRerouteNotificationExpectation = expectation(forNotification: .routeControllerWillReroute, object: router) { (notification) -> Bool in
            let fromLocation = notification.userInfo![RouteController.NotificationUserInfoKey.locationKey] as? CLLocation

            XCTAssertTrue(fromLocation == testLocation)

            return true
        }

        let didRerouteNotificationExpectation = expectation(forNotification: .routeControllerDidReroute, object: router, handler: nil)

        let routeProgressDidChangeNotificationExpectation = expectation(forNotification: .routeControllerProgressDidChange, object: router) { (notification) -> Bool in
            let location = notification.userInfo![RouteController.NotificationUserInfoKey.locationKey] as? CLLocation
            let rawLocation = notification.userInfo![RouteController.NotificationUserInfoKey.rawLocationKey] as? CLLocation
            let _ = notification.userInfo![RouteController.NotificationUserInfoKey.routeProgressKey] as! RouteProgress

            XCTAssertTrue(location!.distance(from: rawLocation!) <= distanceThreshold)

            return true
        }
        
        dependencies.navigationService.start()

        // MARK: When told to re-route from location -- `reroute(from:)`
        router.reroute(from: testLocation, along: router.routeProgress)
        
        waitForNavNativeCallbacks()

        // MARK: it tells the delegate & posts a willReroute notification
        XCTAssertTrue(delegate.recentMessages.contains("navigationService(_:willRerouteFrom:)"))
        wait(for: [willRerouteNotificationExpectation], timeout: 0.1)

        // MARK: Upon rerouting successfully...
        directionsClientSpy.fireLastCalculateCompletion(with: routeOptions.waypoints, routes: [alternateRoute], error: nil)

        // MARK: It tells the delegate & posts a didReroute notification
        wait(for: [didRerouteNotificationExpectation], timeout: 3)
        XCTAssertTrue(delegate.recentMessages.contains("navigationService(_:didRerouteAlong:at:proactive:)"))

        // MARK: On the next call to `locationManager(_, didUpdateLocations:)`
        navigationService.locationManager!(navigationService.locationManager, didUpdateLocations: [testLocation])
        waitForNavNativeCallbacks()

        // MARK: It tells the delegate & posts a routeProgressDidChange notification
        XCTAssertTrue(delegate.recentMessages.contains("navigationService(_:didUpdate:with:rawLocation:)"))
        wait(for: [routeProgressDidChangeNotificationExpectation], timeout: 0.1)

        // MARK: It enqueues and flushes a NavigationRerouteEvent
        let expectedEventName = MMEEventTypeNavigationReroute
        let eventsManagerSpy = navigationService.eventsManager as! NavigationEventsManagerSpy
        XCTAssertTrue(eventsManagerSpy.hasFlushedEvent(with: expectedEventName))
        XCTAssertEqual(eventsManagerSpy.flushedEventCount(with: expectedEventName), 1)
    }

    func testGeneratingAnArrivalEvent() {
        let trace = Fixture.generateTrace(for: route).shiftedToPresent()
        let locationManager = ReplayLocationManager(locations: trace)
        locationManager.startDate = Date()
        dependencies = createDependencies(locationSource: locationManager)
        let navigation = dependencies.navigationService

        locationManager.speedMultiplier = 100
        navigation.start()
        let replyFinished = expectation(description: "Replay finished")
        locationManager.onReplayLoopCompleted = { _ in
            replyFinished.fulfill()
            return false
        }
        wait(for: [replyFinished], timeout: 10)

        // MARK: It queues and flushes a Depart event
        let eventsManagerSpy = navigation.eventsManager as! NavigationEventsManagerSpy
        expectation(description: "Depart Event Flushed") {
            eventsManagerSpy.hasFlushedEvent(with: MMEEventTypeNavigationDepart)
        }
        // MARK: When at a valid location just before the last location
        expectation(description: "Pre-arrival delegate message fired") {
            self.delegate.recentMessages.contains("navigationService(_:willArriveAt:after:distance:)")
        }
        // MARK: It tells the delegate that the user did arrive
        expectation(description: "Arrival delegate message fired") {
            self.delegate.recentMessages.contains("navigationService(_:didArriveAt:)")
        }
        waitForExpectations(timeout: 20, handler: nil)

        // MARK: It enqueues and flushes an arrival event
        let expectedEventName = MMEEventTypeNavigationArrive
        XCTAssertTrue(eventsManagerSpy.hasFlushedEvent(with: expectedEventName))
    }

    func testNoReroutesAfterArriving() {
        let now = Date()
        let trace = Fixture.generateTrace(for: route).shiftedToPresent()
        let locationManager = ReplayLocationManager(locations: trace)
        locationManager.startDate = Date()
        locationManager.speedMultiplier = 100

        dependencies = createDependencies(locationSource: locationManager)

        let navigation = dependencies.navigationService

        let replayFinished = expectation(description: "Replay finished")
        locationManager.onReplayLoopCompleted = { _ in
            replayFinished.fulfill()
            return false
        }
        navigation.start()
        wait(for: [replayFinished], timeout: 10)

        let eventsManagerSpy = navigation.eventsManager as! NavigationEventsManagerSpy
        expectation(description: "Depart Event Flushed") {
            eventsManagerSpy.hasFlushedEvent(with: MMEEventTypeNavigationDepart)
        }

        // MARK: It tells the delegate that the user did arrive
        expectation(description: "Arrival delegate message fired") {
            self.delegate.recentMessages.contains("navigationService(_:didArriveAt:)")
        }

        waitForExpectations(timeout: 5, handler: nil)

        // MARK: Continue off route after arrival
        let offRouteCoordinate = trace.map { $0.coordinate }.last!.coordinate(at: 200, facing: 0)
        let offRouteLocations = (0...3).map {
            CLLocation(coordinate: offRouteCoordinate, altitude: -1, horizontalAccuracy: 10, verticalAccuracy: -1, course: -1, speed: 10, timestamp: now + trace.count + $0)
        }

        offRouteLocations.forEach {
            navigation.router.locationManager?(navigation.locationManager, didUpdateLocations: [$0])
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        
        // Make sure configurable delegate is called
        expectation(description: "Should Prevent Reroutes delegate method called") {
            self.delegate.recentMessages.contains("navigationService(_:shouldPreventReroutesWhenArrivingAt:)")
        }

        // We should not reroute here because the user has arrived.
        expectation(description: "Reroute delegate method isn't called") {
            !self.delegate.recentMessages.contains("navigationService(_:didRerouteAlong:)")
        }

        waitForExpectations(timeout: 5, handler: nil)

        // It enqueues and flushes an arrival event
        let expectedEventName = MMEEventTypeNavigationArrive
        XCTAssertTrue(eventsManagerSpy.hasFlushedEvent(with: expectedEventName))
    }

    func testRouteControllerDoesNotHaveRetainCycle() {
        weak var subject: RouteController? = nil

        autoreleasepool {
            let fakeDataSource = RouteControllerDataSourceFake()
            let routeController = RouteController(alongRouteAtIndex: 0, in: initialRouteResponse, options: routeOptions, dataSource: fakeDataSource)
            subject = routeController
        }

        XCTAssertNil(subject, "Expected RouteController not to live beyond autorelease pool")
    }

    func testRouteControllerDoesNotRetainDataSource() {
        weak var subject: RouterDataSource? = nil

        autoreleasepool {
            let fakeDataSource = RouteControllerDataSourceFake()
            _ = RouteController(alongRouteAtIndex: 0, in: initialRouteResponse, options: routeOptions, dataSource: fakeDataSource)
            subject = fakeDataSource
        }

        XCTAssertNil(subject, "Expected LocationManager's Delegate to be nil after RouteController Deinit")
    }

    func testCountdownTimerDefaultAndUpdate() {
        let directions = DirectionsSpy()
        let subject = MapboxNavigationService(routeResponse: initialRouteResponse, routeIndex: 0, routeOptions: routeOptions,  directions: directions)

        XCTAssert(subject.poorGPSTimer.countdownInterval == .milliseconds(2500), "Default countdown interval should be 2500 milliseconds.")

        subject.poorGPSPatience = 5.0
        XCTAssert(subject.poorGPSTimer.countdownInterval == .milliseconds(5000), "Timer should now have a countdown interval of 5000 millseconds.")
    }

    func testMultiLegRoute() {
        let route = Fixture.route(from: "multileg-route", options: routeOptions)
        let trace = Fixture.generateTrace(for: route).shiftedToPresent().qualified()
        let locationManager = ReplayLocationManager(locations: trace)
        locationManager.startDate = Date()
        locationManager.speedMultiplier = 100

        dependencies = createDependencies(locationSource: locationManager)

        let routeOptions = NavigationRouteOptions(coordinates: [
            CLLocationCoordinate2D(latitude: 9.519172, longitude: 47.210823),
            CLLocationCoordinate2D(latitude: 9.52222, longitude: 47.214268),
            CLLocationCoordinate2D(latitude: 47.212326, longitude: 9.512569),
        ])
        let routeResponse = Fixture.routeResponse(from: "multileg-route", options: routeOptions)

        let navigationService = dependencies.navigationService
        let routeController = navigationService.router as! RouteController
        let routeUpdated = expectation(description: "Route Updated")
        routeController.updateRoute(with: .init(routeResponse: routeResponse, routeIndex: 0), routeOptions: nil) {
            success in
            XCTAssertTrue(success)
            routeUpdated.fulfill()
        }
        wait(for: [routeUpdated], timeout: 5)
        locationManager.onTick = { index, _ in
            if index < 32 {
                XCTAssertEqual(routeController.routeProgress.legIndex,0)
            } else {
                XCTAssertEqual(routeController.routeProgress.legIndex, 1)
            }
        }
        let replayFinished = expectation(description: "Replay finished")
        locationManager.onReplayLoopCompleted = { _ in
            replayFinished.fulfill()
            return false
        }
        navigationService.start()
        wait(for: [replayFinished], timeout: 10)

        XCTAssertTrue(delegate.recentMessages.contains("navigationService(_:didArriveAt:)"))
    }

    func testProactiveRerouting() {
        typealias RouterComposition = Router & InternalRouter

        let options = NavigationRouteOptions(coordinates: [
            CLLocationCoordinate2D(latitude: 38.853108, longitude: -77.043331),
            CLLocationCoordinate2D(latitude: 38.910736, longitude: -76.966906),
        ])
        let route = Fixture.route(from: "DCA-Arboretum", options: options)
        let routeResponse = Fixture.routeResponse(from: "DCA-Arboretum", options: options)
        let trace = Fixture.generateTrace(for: route).shiftedToPresent()
        guard let firstLoction = trace.first,
              let lastLocation = trace.last,
              firstLoction != lastLocation else {
                  XCTFail("Invalid trace"); return
              }
        let duration = lastLocation.timestamp.timeIntervalSince(firstLoction.timestamp)

        XCTAssert(duration > RouteControllerProactiveReroutingInterval + RouteControllerMinimumDurationRemainingForProactiveRerouting,
                  "Duration must greater than rerouting interval and minimum duration remaining for proactive rerouting")

        let directions = DirectionsSpy()
        let locationManager = ReplayLocationManager(locations: trace)
        locationManager.startDate = Date()
        locationManager.speedMultiplier = 100
        let service = MapboxNavigationService(routeResponse: routeResponse,
                                              routeIndex: 0,
                                              routeOptions: options,
                                              directions: directions,
                                              locationSource: locationManager)
        service.delegate = delegate
        let router = service.router

        let didRerouteExpectation = expectation(forNotification: .routeControllerDidReroute,
                                                object: router) { (notification) -> Bool in
            let isProactive = notification.userInfo![RouteController.NotificationUserInfoKey.isProactiveKey] as? Bool
            return isProactive == true
        }

        let rerouteTriggeredExpectation = expectation(description: "Proactive reroute triggered")
        locationManager.onTick = { [unowned locationManager] _, _ in
            if (router as! RouterComposition).lastRerouteLocation != nil {
                locationManager.stopUpdatingLocation()
                rerouteTriggeredExpectation.fulfill()
            }
        }

        service.start()

        wait(for: [rerouteTriggeredExpectation], timeout: 10)

        let fasterRouteName = "DCA-Arboretum-dummy-faster-route"
        let fasterOptions = NavigationRouteOptions(coordinates: [
            CLLocationCoordinate2D(latitude: 38.878206, longitude: -77.037265),
            CLLocationCoordinate2D(latitude: 38.910736, longitude: -76.966906),
        ])
        let fasterRoute = Fixture.route(from: fasterRouteName, options: fasterOptions)
        let waypointsForFasterRoute = Fixture.waypoints(from: fasterRouteName, options: fasterOptions)
        directions.fireLastCalculateCompletion(with: waypointsForFasterRoute, routes: [fasterRoute], error: nil)
        
        wait(for: [didRerouteExpectation], timeout: 10)
        XCTAssertTrue(delegate.recentMessages.contains("navigationService(_:didRerouteAlong:at:proactive:)"))
    }

    func testUnimplementedLogging() {
        _unimplementedLoggingState.clear()
        XCTAssertEqual(_unimplementedLoggingState.countWarned(forTypeDescription: "DummyType"), 0)
        struct DummyType: UnimplementedLogging {
            func method1() {
                logUnimplemented(protocolType: DummyType.self, level: .debug)
            }
            func method2() {
                logUnimplemented(protocolType: DummyType.self, level: .debug)
            }
            func method3() {
                logUnimplemented(protocolType: DummyType.self, level: .debug)
            }
        }
        let type = DummyType()
        type.method1()
        XCTAssertEqual(_unimplementedLoggingState.countWarned(forTypeDescription: "DummyType"), 1)
        type.method2()
        XCTAssertEqual(_unimplementedLoggingState.countWarned(forTypeDescription: "DummyType"), 2)
        type.method2()
        XCTAssertEqual(_unimplementedLoggingState.countWarned(forTypeDescription: "DummyType"), 2)
        type.method3()
        XCTAssertEqual(_unimplementedLoggingState.countWarned(forTypeDescription: "DummyType"), 3)
    }
    
    func waitForNavNativeCallbacks(timeout: TimeInterval = 0.2) {
        let waitExpectation = expectation(description: "Waiting for the NatNative callback")
        _ = XCTWaiter.wait(for: [waitExpectation], timeout: timeout)
    }
}

class EmptyNavigationServiceDelegate: NavigationServiceDelegate {}
