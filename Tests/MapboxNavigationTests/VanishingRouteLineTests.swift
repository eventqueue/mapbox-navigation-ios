import XCTest
import MapboxDirections
import TestHelper
import Turf
import MapboxMaps
@testable import MapboxNavigation
@testable import MapboxCoreNavigation

class VanishingRouteLineTests: TestCase {
    var navigationMapView: NavigationMapView!
    
    override func setUp() {
        super.setUp()
        navigationMapView = NavigationMapView(frame: CGRect(origin: .zero, size: .iPhone6Plus))
    }
    
    override func tearDown() {
        navigationMapView = nil
        super.tearDown()
    }
    
    func getRoute() -> Route {
        let routeData = Fixture.JSONFromFileNamed(name: "short_route")
        let routeOptions = NavigationRouteOptions(coordinates: [
            CLLocationCoordinate2DMake(-122.5237429, 37.975393),
            CLLocationCoordinate2DMake(-122.5231413, 37.9750695)
        ])
        let decoder = JSONDecoder()
        decoder.userInfo[.options] = routeOptions
        var testRoute: Route?
        XCTAssertNoThrow(testRoute = try decoder.decode(Route.self, from: routeData))
        guard let route = testRoute else {
            preconditionFailure("Route is invalid.")
        }
        
        return route
    }
    
    func testParseRoutePoints() {
        let routeData = Fixture.JSONFromFileNamed(name: "multileg_route")
        let routeOptions = NavigationRouteOptions(coordinates: [
            CLLocationCoordinate2DMake(-77.1576396, 38.7830304),
            CLLocationCoordinate2DMake(-77.1670888, 38.7756155),
            CLLocationCoordinate2DMake(-77.1534183, 38.7708948),
        ])
        let decoder = JSONDecoder()
        decoder.userInfo[.options] = routeOptions
        var testRoute: Route?
        XCTAssertNoThrow(testRoute = try decoder.decode(Route.self, from: routeData))
        guard let route = testRoute else {
            preconditionFailure("Route is invalid.")
        }
        
        let routePoints = navigationMapView.parseRoutePoints(route: route)
        
        XCTAssertEqual(routePoints.flatList.count, 128)
        XCTAssertEqual(routePoints.nestedList.flatMap{$0}.count, 15)
        XCTAssertEqual(routePoints.flatList[1].latitude, routePoints.flatList[2].latitude)
        XCTAssertEqual(routePoints.flatList[1].longitude, routePoints.flatList[2].longitude)
        XCTAssertEqual(routePoints.flatList[126].latitude, routePoints.flatList[127].latitude, accuracy: 0.000001)
        XCTAssertEqual(routePoints.flatList[126].longitude, routePoints.flatList[127].longitude, accuracy: 0.000001)
    }
    
    func testUpdateUpcomingRoutePointIndex() {
        let route = getRoute()
        
        navigationMapView.initPrimaryRoutePoints(route: route)
        navigationMapView.routeLineGranularDistances = nil
        XCTAssertEqual(navigationMapView.fractionTraveled, 0.0)
        
        let routeProgress = RouteProgress(route: route, options: routeOptions, legIndex: 0, spokenInstructionIndex: 0)
        routeProgress.currentLegProgress = RouteLegProgress(leg: route.legs[0], stepIndex: 2, spokenInstructionIndex: 0)
        routeProgress.currentLegProgress.currentStepProgress = RouteStepProgress(step: route.legs[0].steps[2], spokenInstructionIndex: 0)
        
        navigationMapView.updateUpcomingRoutePointIndex(routeProgress: routeProgress)
        
        XCTAssertEqual(navigationMapView.routeRemainingDistancesIndex, 6)
    }
    
    func testUpdateUpcomingRoutePointIndexWhenPrimaryRoutePointsIsNill() {
        let route = getRoute()
        let routeProgress = RouteProgress(route: route, options: routeOptions, legIndex: 0, spokenInstructionIndex: 0)
        routeProgress.currentLegProgress = RouteLegProgress(leg: route.legs[0], stepIndex: 2, spokenInstructionIndex: 0)
        routeProgress.currentLegProgress.currentStepProgress = RouteStepProgress(step: route.legs[0].steps[2], spokenInstructionIndex: 0)
        
        navigationMapView.updateUpcomingRoutePointIndex(routeProgress: routeProgress)
        XCTAssertNil(navigationMapView.routeRemainingDistancesIndex)
    }
    
    func testUpdateFractionTraveled() {
        let route = getRoute()
        let routeProgress = RouteProgress(route: route, options: routeOptions, legIndex: 0, spokenInstructionIndex: 0)
        routeProgress.currentLegProgress = RouteLegProgress(leg: route.legs[0], stepIndex: 2, spokenInstructionIndex: 0)
        routeProgress.currentLegProgress.currentStepProgress = RouteStepProgress(step: route.legs[0].steps[2], spokenInstructionIndex: 0)
        
        let coordinate = route.shape!.coordinates[1]
        navigationMapView.routeLineTracksTraversal = true
        navigationMapView.show([route])
        navigationMapView.updateUpcomingRoutePointIndex(routeProgress: routeProgress)
        navigationMapView.updateFractionTraveled(coordinate: coordinate)
        
        XCTAssertEqual(navigationMapView.fractionTraveled, 0.3240769449298392, accuracy: 0.0000000001)
    }
    
}
