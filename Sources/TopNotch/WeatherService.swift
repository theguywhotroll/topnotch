import CoreLocation
import Foundation
import MapKit

struct WeatherSnapshot {
    let temperatureCelsius: Int
    let condition: String
    let symbol: String
}

/// Owns location access for weather and time-to-leave estimates.
@MainActor
final class WeatherService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var lastFetch: Date?
    private var lastAttempt: Date?
    private var requestedAuthorization = false
    private(set) var latestLocation: CLLocation?
    var wantsWeather = false
    var onUpdate: ((WeatherSnapshot?) -> Void)?
    var onError: ((String) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    var isAuthorized: Bool {
        manager.authorizationStatus == .authorized || manager.authorizationStatus == .authorizedAlways
    }

    func refreshIfNeeded() {
        if let lastFetch, Date().timeIntervalSince(lastFetch) < 20 * 60 { return }
        if let latestLocation, Date().timeIntervalSince(latestLocation.timestamp) < 20 * 60 {
            fetch(at: latestLocation.coordinate)
            return
        }
        requestLocationIfNeeded()
    }

    /// Requests a location fix at most every five minutes, or immediately when forced.
    func requestLocationIfNeeded(force: Bool = false) {
        if !force, let latestLocation, Date().timeIntervalSince(latestLocation.timestamp) < 10 * 60 { return }
        if !force, let lastAttempt, Date().timeIntervalSince(lastAttempt) < 5 * 60 { return }
        switch manager.authorizationStatus {
        case .authorized, .authorizedAlways:
            lastAttempt = Date()
            manager.requestLocation()
        case .notDetermined:
            if !requestedAuthorization || force {
                requestedAuthorization = true
                manager.requestWhenInUseAuthorization()
            }
        case .denied, .restricted:
            lastAttempt = Date()
            onError?("Allow location access in System Settings to show weather.")
        @unknown default:
            break
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.handleAuthorizationChange() }
    }

    private func handleAuthorizationChange() {
        if isAuthorized {
            lastAttempt = Date()
            manager.requestLocation()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.latestLocation = location
            if self.wantsWeather { self.fetch(at: location.coordinate) }
        }
    }

    private func fetch(at coordinate: CLLocationCoordinate2D) {
        if let lastFetch, Date().timeIntervalSince(lastFetch) < 20 * 60 { return }
        lastFetch = Date()
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.2f", coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.2f", coordinate.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "timezone", value: "auto")
        ]
        guard let url = components.url else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            let validResponse = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            let result = validResponse ? data.flatMap { try? JSONDecoder().decode(ForecastResponse.self, from: $0) } : nil
            DispatchQueue.main.async {
                if let result {
                    self?.onUpdate?(WeatherService.describe(result.current))
                } else {
                    self?.lastFetch = nil
                    self?.onError?(error?.localizedDescription ?? "Weather is temporarily unavailable.")
                }
            }
        }.resume()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.onError?(error.localizedDescription) }
    }

    private struct ForecastResponse: Decodable {
        let current: Current
    }

    private struct Current: Decodable {
        let temperature_2m: Double
        let weather_code: Int
    }

    private static func describe(_ current: Current) -> WeatherSnapshot {
        let condition: String
        let symbol: String
        switch current.weather_code {
        case 0: (condition, symbol) = ("Clear", "sun.max.fill")
        case 1...3: (condition, symbol) = ("Cloudy", "cloud.sun.fill")
        case 45...48: (condition, symbol) = ("Fog", "cloud.fog.fill")
        case 51...67: (condition, symbol) = ("Rain", "cloud.rain.fill")
        case 71...86: (condition, symbol) = ("Snow", "cloud.snow.fill")
        case 95...99: (condition, symbol) = ("Thunderstorm", "cloud.bolt.rain.fill")
        default: (condition, symbol) = ("Weather", "cloud.fill")
        }
        return WeatherSnapshot(temperatureCelsius: Int(current.temperature_2m.rounded()), condition: condition, symbol: symbol)
    }
}

/// Estimates travel time to an event's location with MapKit. Results are cached per event and mode;
/// `estimate` returns nil until the first lookup finishes.
@MainActor
final class TravelTimeService {
    private var cache: [String: TimeInterval] = [:]
    private var attempted: [String: Date] = [:]

    func estimate(for event: CalendarEvent, from origin: CLLocation, mode: TransportMode) -> TimeInterval? {
        let key = "\(event.id)|\(mode.rawValue)"
        if let cached = cache[key] { return cached }
        if let last = attempted[key], Date().timeIntervalSince(last) < 10 * 60 { return nil }
        attempted[key] = Date()
        Task { await self.lookUp(key: key, event: event, origin: origin, mode: mode) }
        return nil
    }

    private func lookUp(key: String, event: CalendarEvent, origin: CLLocation, mode: TransportMode) async {
        let destination: CLLocationCoordinate2D
        if let geo = event.geoLocation {
            destination = CLLocationCoordinate2D(latitude: geo.latitude, longitude: geo.longitude)
        } else if let address = event.location,
                  let placemark = try? await CLGeocoder().geocodeAddressString(address).first,
                  let coordinate = placemark.location?.coordinate {
            destination = coordinate
        } else {
            return
        }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.departureDate = Date()
        switch mode {
        case .drive: request.transportType = .automobile
        case .transit: request.transportType = .transit
        case .walk: request.transportType = .walking
        }
        if let response = try? await MKDirections(request: request).calculateETA() {
            cache[key] = response.expectedTravelTime
        }
    }
}
