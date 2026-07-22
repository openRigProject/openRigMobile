import CarPlay
import CoreLocation
import Flutter
import MapKit

@available(iOS 14.0, *)
class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    var interfaceController: CPInterfaceController?
    private var carWindow: UIWindow?
    private var mapViewController: CarPlayMapViewController?
    private var methodChannel: FlutterMethodChannel?
    private var refreshTimer: Timer?
    private var stations: [[String: Any]] = []
    private let locationManager = CLLocationManager()

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController

        // Create a window for the CarPlay display and add a map view
        let mapVC = CarPlayMapViewController()
        mapVC.onStationSelected = { [weak self] station in
            self?.showStationDetail(station)
        }
        mapVC.onMapMoved = { [weak self] lat, lon, zoom in
            self?.methodChannel?.invokeMethod("mapCenterChanged", arguments: ["lat": lat, "lon": lon, "zoom": zoom])
        }
        self.mapViewController = mapVC

        let window = templateApplicationScene.carWindow
        window.rootViewController = mapVC
        window.makeKeyAndVisible()
        self.carWindow = window

        // Set up FlutterMethodChannel using the shared binary messenger from AppDelegate
        if let messenger = AppDelegate.sharedBinaryMessenger {
            methodChannel = FlutterMethodChannel(
                name: "com.openrig.mobile/carplay",
                binaryMessenger: messenger
            )

            methodChannel?.setMethodCallHandler { [weak self] call, result in
                switch call.method {
                case "updateStations":
                    if let data = call.arguments as? [[String: Any]] {
                        self?.stations = data
                        self?.mapViewController?.updateStations(data)
                        self?.updateMapTemplate()
                    }
                    result(nil)
                case "updateMapCenter":
                    if let args = call.arguments as? [String: Any],
                       let lat = args["lat"] as? Double,
                       let lon = args["lon"] as? Double,
                       let zoom = args["zoom"] as? Double {
                        self?.mapViewController?.syncCenter(lat: lat, lon: lon, zoom: zoom)
                    }
                    result(nil)
                default:
                    result(FlutterMethodNotImplemented)
                }
            }
            NSLog("[CarPlay] Method channel connected via shared binary messenger")
        } else {
            NSLog("[CarPlay] ERROR: sharedBinaryMessenger is nil — method channel not connected")
        }

        // Show the map template
        let mapTemplate = createMapTemplate()
        interfaceController.setRootTemplate(mapTemplate, animated: true, completion: nil)

        // Request location for the recenter button
        locationManager.requestWhenInUseAuthorization()

        // Fetch initial station data and start periodic refresh
        refreshStations()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshStations()
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        self.interfaceController = nil
        self.carWindow?.isHidden = true
        self.carWindow = nil
        self.mapViewController = nil
        self.methodChannel?.setMethodCallHandler(nil)
        self.methodChannel = nil
    }

    // MARK: - Map Template

    private func createMapTemplate() -> CPMapTemplate {
        let mapTemplate = CPMapTemplate()
        mapTemplate.mapDelegate = mapViewController

        // Zoom buttons
        let zoomIn = CPMapButton { [weak self] _ in
            self?.mapViewController?.zoomIn()
        }
        zoomIn.image = UIImage(systemName: "plus.magnifyingglass")

        let zoomOut = CPMapButton { [weak self] _ in
            self?.mapViewController?.zoomOut()
        }
        zoomOut.image = UIImage(systemName: "minus.magnifyingglass")

        let recenter = CPMapButton { [weak self] _ in
            self?.centerOnCurrentLocation()
        }
        recenter.image = UIImage(systemName: "location.fill")

        mapTemplate.mapButtons = [zoomIn, zoomOut, recenter]

        // Station list button in the navigation bar
        let listButton = CPBarButton(title: "Stations") { [weak self] _ in
            self?.showStationList()
        }
        mapTemplate.leadingNavigationBarButtons = [listButton]

        return mapTemplate
    }

    private func centerOnCurrentLocation() {
        if let loc = locationManager.location {
            mapViewController?.centerOn(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
            // Also sync to phone
            let zoom = 10.0
            methodChannel?.invokeMethod("mapCenterChanged", arguments: [
                "lat": loc.coordinate.latitude,
                "lon": loc.coordinate.longitude,
                "zoom": zoom,
            ])
        }
    }

    private func updateMapTemplate() {
        if let mapTemplate = interfaceController?.rootTemplate as? CPMapTemplate {
            let count = stations.count
            if count > 0 {
                let subtitle = "\(count) station\(count == 1 ? "" : "s")"
                let listButton = CPBarButton(title: subtitle) { [weak self] _ in
                    self?.showStationList()
                }
                mapTemplate.leadingNavigationBarButtons = [listButton]
            }
        }
    }

    // MARK: - Station List

    private func showStationList() {
        if stations.isEmpty {
            let emptyItem = CPListItem(
                text: "No Stations",
                detailText: "Add callsigns to track in the app"
            )
            let section = CPListSection(items: [emptyItem])
            let template = CPListTemplate(
                title: "APRS Stations",
                sections: [section]
            )
            interfaceController?.pushTemplate(template, animated: true, completion: nil)
            return
        }

        let items: [CPListItem] = stations.prefix(12).map { station in
            let callsign = station["callsign"] as? String ?? "Unknown"
            let detail = station["detail"] as? String ?? ""
            let lastTime = station["lastTime"] as? String ?? ""
            let timeAgo = formatRelativeTime(lastTime)
            let subtitle = detail.isEmpty ? timeAgo : "\(detail) \u{2022} \(timeAgo)"

            let item = CPListItem(
                text: callsign,
                detailText: subtitle,
                image: UIImage(systemName: "antenna.radiowaves.left.and.right")
            )
            item.handler = { [weak self] _, completion in
                self?.showStationDetail(station)
                if let lat = station["lat"] as? Double,
                   let lon = station["lon"] as? Double {
                    self?.mapViewController?.centerOn(lat: lat, lon: lon)
                }
                completion()
            }
            return item
        }

        let section = CPListSection(items: items)
        let template = CPListTemplate(
            title: "APRS Stations",
            sections: [section]
        )
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    // MARK: - Station Detail

    private func showStationDetail(_ station: [String: Any]) {
        let callsign = station["callsign"] as? String ?? "Unknown"
        let detail = station["detail"] as? String ?? ""
        let comment = station["comment"] as? String ?? ""
        let speed = station["speed"] as? String ?? ""
        let altitude = station["altitude"] as? String ?? ""
        let lastTime = station["lastTime"] as? String ?? ""

        var infoItems = [
            CPInformationItem(title: "Position", detail: detail),
        ]

        if !speed.isEmpty && speed != "0.0" {
            infoItems.append(CPInformationItem(title: "Speed", detail: "\(speed) km/h"))
        }
        if !altitude.isEmpty {
            infoItems.append(CPInformationItem(title: "Altitude", detail: "\(altitude) m"))
        }
        if !comment.isEmpty {
            infoItems.append(CPInformationItem(title: "Comment", detail: comment))
        }
        infoItems.append(CPInformationItem(title: "Last Heard", detail: formatRelativeTime(lastTime)))

        let template = CPInformationTemplate(
            title: callsign,
            layout: .leading,
            items: infoItems,
            actions: []
        )

        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    // MARK: - Data

    private func refreshStations() {
        methodChannel?.invokeMethod("getAprsStations", arguments: nil) { [weak self] result in
            guard let stations = result as? [[String: Any]] else { return }
            self?.stations = stations
            self?.mapViewController?.updateStations(stations)
            self?.updateMapTemplate()
        }
    }

    private func formatRelativeTime(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: isoString) ?? ISO8601DateFormatter().date(from: isoString) else {
            return ""
        }
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }
}

// MARK: - CarPlay Map View Controller

@available(iOS 14.0, *)
class CarPlayMapViewController: UIViewController, CPMapTemplateDelegate {
    private var mapView: MKMapView!
    private var stations: [[String: Any]] = []
    private var isSyncingFromPhone = false

    var onStationSelected: (([String: Any]) -> Void)?
    var onMapMoved: ((Double, Double, Double) -> Void)?  // lat, lon, zoom

    override func viewDidLoad() {
        super.viewDidLoad()

        mapView = MKMapView(frame: view.bounds)
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.showsUserLocation = true
        mapView.delegate = self

        // Use OpenStreetMap tiles to match the in-app map
        let osmOverlay = MKTileOverlay(urlTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png")
        osmOverlay.canReplaceMapContent = true
        mapView.addOverlay(osmOverlay, level: .aboveLabels)

        // Default to a wide view of the US
        let center = CLLocationCoordinate2D(latitude: 39.8, longitude: -98.5)
        let region = MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: 40, longitudeDelta: 60)
        )
        mapView.setRegion(region, animated: false)

        view.addSubview(mapView)
    }

    func updateStations(_ newStations: [[String: Any]]) {
        self.stations = newStations

        // Remove old annotations
        let existing = mapView.annotations.filter { !($0 is MKUserLocation) }
        mapView.removeAnnotations(existing)

        // Add new annotations
        var annotations: [StationAnnotation] = []
        for station in newStations {
            guard let callsign = station["callsign"] as? String,
                  let latitude = station["lat"] as? Double,
                  let longitude = station["lon"] as? Double,
                  latitude != 0 || longitude != 0 else { continue }

            let annotation = StationAnnotation(
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                callsign: callsign,
                stationData: station
            )
            annotations.append(annotation)
        }

        mapView.addAnnotations(annotations)

        // Zoom to fit all stations if we have any
        if !annotations.isEmpty {
            mapView.showAnnotations(annotations, animated: true)
        }
    }

    func zoomIn() {
        var region = mapView.region
        region.span.latitudeDelta /= 2
        region.span.longitudeDelta /= 2
        mapView.setRegion(region, animated: true)
    }

    func zoomOut() {
        var region = mapView.region
        region.span.latitudeDelta = min(region.span.latitudeDelta * 2, 180)
        region.span.longitudeDelta = min(region.span.longitudeDelta * 2, 360)
        mapView.setRegion(region, animated: true)
    }

    func recenterOnStations() {
        let annotations = mapView.annotations.filter { !($0 is MKUserLocation) }
        if !annotations.isEmpty {
            mapView.showAnnotations(annotations, animated: true)
        }
    }

    func centerOn(lat: Double, lon: Double) {
        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        let region = MKCoordinateRegion(
            center: coord,
            span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
        )
        mapView.setRegion(region, animated: true)
    }

    /// Sync map center/zoom from the phone app.
    func syncCenter(lat: Double, lon: Double, zoom: Double) {
        isSyncingFromPhone = true
        // flutter_map zoom → MKMapView longitude span.
        // Using same formula in both directions for round-trip stability.
        let lonSpan = 360.0 / pow(2.0, zoom)
        let latRadians = lat * .pi / 180.0
        let latSpan = lonSpan * cos(latRadians)

        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        let region = MKCoordinateRegion(
            center: coord,
            span: MKCoordinateSpan(latitudeDelta: latSpan, longitudeDelta: lonSpan)
        )
        // No animation — ensures regionDidChangeAnimated fires immediately
        // while isSyncingFromPhone is still true.
        mapView.setRegion(region, animated: false)
        isSyncingFromPhone = false
    }
}

// MARK: - MKMapViewDelegate

@available(iOS 14.0, *)
extension CarPlayMapViewController: MKMapViewDelegate {
    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        guard let stationAnnotation = annotation as? StationAnnotation else { return nil }

        let identifier = "StationPin"
        var view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
        if view == nil {
            view = MKMarkerAnnotationView(annotation: stationAnnotation, reuseIdentifier: identifier)
            view?.canShowCallout = true
            view?.calloutOffset = CGPoint(x: 0, y: -5)
        } else {
            view?.annotation = stationAnnotation
        }

        view?.glyphImage = UIImage(systemName: "antenna.radiowaves.left.and.right")
        view?.markerTintColor = .systemBlue
        view?.titleVisibility = .visible

        return view
    }

    func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
        guard let stationAnnotation = annotation as? StationAnnotation else { return }
        onStationSelected?(stationAnnotation.stationData)
    }

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        guard !isSyncingFromPhone else { return }
        let center = mapView.region.center
        // Reverse: lonSpan = 360 / 2^zoom  →  zoom = log2(360 / lonSpan)
        let lonSpan = mapView.region.span.longitudeDelta
        let zoom = log2(360.0 / max(lonSpan, 0.001))
        onMapMoved?(center.latitude, center.longitude, zoom)
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if let tileOverlay = overlay as? MKTileOverlay {
            return MKTileOverlayRenderer(tileOverlay: tileOverlay)
        }
        return MKOverlayRenderer(overlay: overlay)
    }
}

// MARK: - Station Annotation

class StationAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let callsign: String
    let stationData: [String: Any]

    var title: String? { callsign }
    var subtitle: String? {
        let comment = stationData["comment"] as? String ?? ""
        return comment.isEmpty ? nil : comment
    }

    init(coordinate: CLLocationCoordinate2D, callsign: String, stationData: [String: Any]) {
        self.coordinate = coordinate
        self.callsign = callsign
        self.stationData = stationData
        super.init()
    }
}
