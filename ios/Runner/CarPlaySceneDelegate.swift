import CarPlay
import CoreLocation
import Flutter
import MapKit

enum CarPlayMapMode {
    case aprs
    case lastHeard
}

@available(iOS 14.0, *)
class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    var interfaceController: CPInterfaceController?
    private var carWindow: UIWindow?
    private var mapViewController: CarPlayMapViewController?
    private var methodChannel: FlutterMethodChannel?
    private var refreshTimer: Timer?
    private var stations: [[String: Any]] = []
    private var lastHeardData: [String: Any]?
    private var mapMode: CarPlayMapMode = .aprs
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
                        if self?.mapMode == .aprs {
                            self?.mapViewController?.updateStations(data)
                        }
                        self?.updateNavButtons()
                    }
                    result(nil)
                case "updateLastHeard":
                    if let data = call.arguments as? [String: Any] {
                        self?.lastHeardData = data
                        if self?.mapMode == .lastHeard {
                            self?.showLastHeardOnMap(data)
                        }
                        self?.updateNavButtons()
                    }
                    result(nil)
                case "clearLastHeard":
                    self?.lastHeardData = nil
                    if self?.mapMode == .lastHeard {
                        self?.mapViewController?.updateStations([])
                        self?.mapViewController?.hideQsoOverlay()
                    }
                    self?.updateNavButtons()
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
        fetchLastHeard()
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

        // Nav bar buttons
        updateNavButtons(mapTemplate: mapTemplate)

        return mapTemplate
    }

    private func updateNavButtons(mapTemplate: CPMapTemplate? = nil) {
        guard let template = mapTemplate ?? (interfaceController?.rootTemplate as? CPMapTemplate) else { return }

        // Leading: context button (station list or last heard info)
        let leadingTitle: String
        switch mapMode {
        case .aprs:
            let count = stations.count
            leadingTitle = count > 0 ? "\(count) station\(count == 1 ? "" : "s")" : "Stations"
        case .lastHeard:
            leadingTitle = lastHeardData?["callsign"] as? String ?? "Last Heard"
        }
        let listButton = CPBarButton(title: leadingTitle) { [weak self] _ in
            switch self?.mapMode {
            case .aprs:
                self?.showStationList()
            case .lastHeard:
                if let data = self?.lastHeardData {
                    self?.showLastHeardDetail(data)
                }
            case .none:
                break
            }
        }
        template.leadingNavigationBarButtons = [listButton]

        // Trailing: mode toggle
        let toggleTitle = mapMode == .aprs ? "Hotspot" : "APRS"
        let toggleButton = CPBarButton(title: toggleTitle) { [weak self] _ in
            self?.toggleMapMode()
        }
        template.trailingNavigationBarButtons = [toggleButton]
    }

    private func toggleMapMode() {
        switch mapMode {
        case .aprs:
            mapMode = .lastHeard
            if let data = lastHeardData {
                showLastHeardOnMap(data)
            } else {
                mapViewController?.updateStations([])
                mapViewController?.hideQsoOverlay()
            }
        case .lastHeard:
            mapMode = .aprs
            mapViewController?.hideQsoOverlay()
            mapViewController?.updateStations(stations)
        }
        updateNavButtons()
    }

    private func showLastHeardOnMap(_ data: [String: Any]) {
        let callsign = data["callsign"] as? String ?? ""
        let lat = data["lat"] as? Double ?? 0.0
        let lon = data["lon"] as? Double ?? 0.0
        let mode = data["mode"] as? String ?? ""
        let info = data["info"] as? String ?? ""
        let duration = data["duration"] as? String ?? ""
        let isActive = data["isActive"] as? Bool ?? false
        let name = data["name"] as? String ?? ""
        let location = data["location"] as? String ?? ""
        let grid = data["grid"] as? String ?? ""
        let freqMhz = data["freqMhz"] as? Double ?? 0.0

        // Update map marker (autoZoom false — flyTo handles camera)
        if lat != 0 || lon != 0 {
            let stationData: [String: Any] = [
                "callsign": callsign,
                "lat": lat,
                "lon": lon,
                "comment": "\(mode) \(info)".trimmingCharacters(in: .whitespaces),
            ]
            mapViewController?.updateStations([stationData], autoZoom: false)
            mapViewController?.flyTo(lat: lat, lon: lon)
        } else {
            mapViewController?.updateStations([])
        }

        // Build overlay text
        var lines: [String] = []
        lines.append("\(callsign)  \(mode)")
        if !info.isEmpty { lines[0] += "  \(info)" }
        if !name.isEmpty { lines.append(name) }
        if !location.isEmpty { lines.append(location) }

        var detailParts: [String] = []
        if freqMhz > 0 { detailParts.append(String(format: "%.4f MHz", freqMhz)) }
        if !grid.isEmpty { detailParts.append(grid) }
        if isActive {
            detailParts.append("LIVE")
        } else if !duration.isEmpty {
            detailParts.append(duration)
        }
        if !detailParts.isEmpty { lines.append(detailParts.joined(separator: "  •  ")) }

        mapViewController?.showQsoOverlay(lines: lines, isActive: isActive)
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

    // MARK: - Station List (APRS mode)

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

    // MARK: - Station Detail (APRS mode)

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

    // MARK: - Last Heard Detail

    private func showLastHeardDetail(_ data: [String: Any]) {
        let callsign = data["callsign"] as? String ?? "Unknown"
        let mode = data["mode"] as? String ?? ""
        let info = data["info"] as? String ?? ""
        let duration = data["duration"] as? String ?? ""
        let isActive = data["isActive"] as? Bool ?? false
        let name = data["name"] as? String ?? ""
        let location = data["location"] as? String ?? ""
        let grid = data["grid"] as? String ?? ""
        let freqMhz = data["freqMhz"] as? Double ?? 0.0

        var infoItems: [CPInformationItem] = []
        infoItems.append(CPInformationItem(title: "Mode", detail: mode))
        if !info.isEmpty {
            infoItems.append(CPInformationItem(title: "Info", detail: info))
        }
        if !name.isEmpty {
            infoItems.append(CPInformationItem(title: "Name", detail: name))
        }
        if !location.isEmpty {
            infoItems.append(CPInformationItem(title: "Location", detail: location))
        }
        if !grid.isEmpty {
            infoItems.append(CPInformationItem(title: "Grid", detail: grid))
        }
        if freqMhz > 0 {
            infoItems.append(CPInformationItem(title: "Frequency", detail: String(format: "%.4f MHz", freqMhz)))
        }
        let status = isActive ? "LIVE" : (!duration.isEmpty ? duration : "—")
        infoItems.append(CPInformationItem(title: "Status", detail: status))

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
            if self?.mapMode == .aprs {
                self?.mapViewController?.updateStations(stations)
            }
            self?.updateNavButtons()
        }
    }

    private func fetchLastHeard() {
        methodChannel?.invokeMethod("getLastHeard", arguments: nil) { [weak self] result in
            guard let data = result as? [String: Any] else { return }
            self?.lastHeardData = data
            if self?.mapMode == .lastHeard {
                self?.showLastHeardOnMap(data)
            }
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
    private var qsoOverlayView: QsoOverlayView?

    // Fly-to animation state
    private var displayLink: CADisplayLink?
    private var flyFromLat: Double = 0
    private var flyFromLon: Double = 0
    private var flyToLat: Double = 0
    private var flyToLon: Double = 0
    private var flyStartZoom: Double = 6
    private var flyEndZoom: Double = 6
    private var flyMinZoom: Double = 3
    private var flyDuration: TimeInterval = 0.7
    private var flyStartTime: TimeInterval = 0

    var onStationSelected: (([String: Any]) -> Void)?
    var onMapMoved: ((Double, Double, Double) -> Void)?  // lat, lon, zoom

    override func viewDidLoad() {
        super.viewDidLoad()

        mapView = MKMapView(frame: view.bounds)
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.showsUserLocation = true
        mapView.delegate = self

        // Default to a wide view of the US
        let center = CLLocationCoordinate2D(latitude: 39.8, longitude: -98.5)
        let region = MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: 40, longitudeDelta: 60)
        )
        mapView.setRegion(region, animated: false)

        view.addSubview(mapView)
    }

    func updateStations(_ newStations: [[String: Any]], autoZoom: Bool = true) {
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

        // Zoom to fit all stations if we have any (skip when flyTo will handle it)
        if autoZoom && !annotations.isEmpty {
            mapView.showAnnotations(annotations, animated: true)
        }
    }

    func showQsoOverlay(lines: [String], isActive: Bool) {
        if qsoOverlayView == nil {
            let overlay = QsoOverlayView()
            view.addSubview(overlay)
            overlay.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
                overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
                overlay.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            ])
            qsoOverlayView = overlay
        }
        qsoOverlayView?.update(lines: lines, isActive: isActive)
        qsoOverlayView?.isHidden = false
    }

    func hideQsoOverlay() {
        qsoOverlayView?.isHidden = true
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

    /// Animated fly-to matching the phone's map_widget.dart behavior:
    /// distance-based zoom arc that zooms out then back in.
    func flyTo(lat: Double, lon: Double) {
        let fromCenter = mapView.region.center
        let fromLat = fromCenter.latitude
        let fromLon = fromCenter.longitude

        // Calculate distance in km (Haversine)
        let distKm = haversineKm(lat1: fromLat, lon1: fromLon, lat2: lat, lon2: lon)

        // Match the phone's distance thresholds
        let minZoom: Double
        let duration: TimeInterval
        if distKm > 8000 {
            minZoom = 2.5; duration = 2.8
        } else if distKm > 4000 {
            minZoom = 3.0; duration = 2.4
        } else if distKm > 2000 {
            minZoom = 3.5; duration = 2.0
        } else if distKm > 800 {
            minZoom = 4.0; duration = 1.5
        } else if distKm > 200 {
            minZoom = 4.5; duration = 1.0
        } else if distKm > 10 {
            minZoom = 5.5; duration = 0.7
        } else {
            // Very close — just pan without zoom arc
            centerOn(lat: lat, lon: lon)
            return
        }

        // Current zoom from span
        let currentLonSpan = mapView.region.span.longitudeDelta
        let currentZoom = log2(360.0 / max(currentLonSpan, 0.001))

        flyFromLat = fromLat
        flyFromLon = fromLon
        flyToLat = lat
        flyToLon = lon
        flyStartZoom = currentZoom
        flyEndZoom = 6.0
        flyMinZoom = minZoom
        flyDuration = duration
        flyStartTime = CACurrentMediaTime()

        displayLink?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(flyAnimationTick))
        link.add(to: .main, forMode: .default)
        displayLink = link
    }

    @objc private func flyAnimationTick() {
        let elapsed = CACurrentMediaTime() - flyStartTime
        var t = elapsed / flyDuration
        if t >= 1.0 {
            t = 1.0
            displayLink?.invalidate()
            displayLink = nil
        }

        // Ease in-out
        let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2

        // Interpolate position
        let lat = flyFromLat + (flyToLat - flyFromLat) * eased
        let lon = flyFromLon + (flyToLon - flyFromLon) * eased

        // Parabolic zoom arc: dips to flyMinZoom at t=0.5, recovers to flyEndZoom
        let zoomDip = (flyStartZoom - flyMinZoom) * sin(.pi * t)
        let zoom = flyStartZoom - zoomDip + (flyEndZoom - flyStartZoom) * t

        // Convert zoom to span
        let lonSpan = 360.0 / pow(2.0, zoom)
        let latRadians = lat * .pi / 180.0
        let latSpan = lonSpan * cos(latRadians)

        isSyncingFromPhone = true
        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        let region = MKCoordinateRegion(
            center: coord,
            span: MKCoordinateSpan(latitudeDelta: latSpan, longitudeDelta: lonSpan)
        )
        mapView.setRegion(region, animated: false)
        isSyncingFromPhone = false
    }

    private func haversineKm(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let r = 6371.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) +
                cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) *
                sin(dLon / 2) * sin(dLon / 2)
        return r * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    /// Sync map center/zoom from the phone app.
    func syncCenter(lat: Double, lon: Double, zoom: Double) {
        isSyncingFromPhone = true
        let lonSpan = 360.0 / pow(2.0, zoom)
        let latRadians = lat * .pi / 180.0
        let latSpan = lonSpan * cos(latRadians)

        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        let region = MKCoordinateRegion(
            center: coord,
            span: MKCoordinateSpan(latitudeDelta: latSpan, longitudeDelta: lonSpan)
        )
        mapView.setRegion(region, animated: false)
        isSyncingFromPhone = false
    }
}

// MARK: - QSO Info Overlay

class QsoOverlayView: UIView {
    private let stackView = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.75)
        layer.cornerRadius = 10
        clipsToBounds = true

        stackView.axis = .vertical
        stackView.spacing = 2
        stackView.alignment = .leading
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(lines: [String], isActive: Bool) {
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for (index, line) in lines.enumerated() {
            let label = UILabel()
            label.text = line
            label.textColor = .white
            label.numberOfLines = 1

            if index == 0 {
                // First line: callsign + mode — large and bold
                label.font = UIFont.boldSystemFont(ofSize: 18)
                if isActive {
                    label.textColor = UIColor.systemGreen
                }
            } else {
                label.font = UIFont.systemFont(ofSize: 14)
                label.textColor = UIColor.lightGray
            }

            stackView.addArrangedSubview(label)
        }
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
        let lonSpan = mapView.region.span.longitudeDelta
        let zoom = log2(360.0 / max(lonSpan, 0.001))
        onMapMoved?(center.latitude, center.longitude, zoom)
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
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
