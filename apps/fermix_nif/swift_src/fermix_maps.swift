// fermix-maps: one Apple Maps place search per process, for place_search's
// `apple_maps` backend (M72 §14). The engine spawns it through the disclaim
// shim, writes one request line, reads one JSON object, and kills its process
// group at its own bound.
//
// Usage:  fermix-maps            reads one request, a JSON object on one line, from stdin
//         fermix-maps --check    prints "fermix-maps: ok" and exits 0, touching no network
//
// Request, one of three anchors:
//   {"query": "coffee", "anchor": {"kind": "query_only"}}
//   {"query": "coffee", "anchor": {"kind": "location", "location": "SoHo, New York"}}
//   {"query": "coffee", "anchor": {"kind": "coordinates", "latitude": 40.72,
//                                  "longitude": -74.0, "radius_meters": 5000}}
//
// A named location is geocoded once with CLGeocoder and its placemark's region
// sizes the search; coordinates are a region of `radius_meters`, a hint and not
// a geofence. Nothing here creates a CLLocationManager or reads where this Mac
// is: that would raise a Location prompt under this helper's own name, and the
// person's position is never an input (M31 §13.2).
//
// Success: exit 0 and {"places": [...]}, each place MapKit's raw fields, every
// one but `name` present only when MapKit gave it: name, latitude, longitude,
// identifier, url, phone, category, address. Normalizing them is the engine's
// job. A search that finds nothing is {"places": []}.
//
// Failure: {"error": {"message": "..."}} with the framework's own words, never
// the request's values, and a distinct exit status:
//   64 usage       the request is not one valid request
//   65 not_found   the named location geocoded to no place
//   66 throttled   MapKit or the geocoder is throttling this Mac
//   67 network     the network was unavailable
//   68 failed      MapKit or the geocoder failed otherwise
//   69 timed_out   no answer within this helper's own bound
// 70, 71, 72, 74 and 75 are the disclaim shim's, before this program runs.
//
// Everything used here exists on macOS 15, the build's deployment target, so a
// newer API is a compile error rather than a crash on an older Mac.

import CoreLocation
import Foundation
import MapKit

enum Failure: Int32 {
  case usage = 64
  case notFound = 65
  case throttled = 66
  case network = 67
  case failed = 68
  case timedOut = 69
}

enum Anchor {
  case queryOnly
  case location(String)
  case coordinates(CLLocationCoordinate2D, CLLocationDistance)
}

struct SearchRequest {
  let query: String
  let anchor: Anchor
}

struct Place: Encodable {
  let name: String?
  let latitude: Double?
  let longitude: Double?
  let identifier: String?
  let url: String?
  let phone: String?
  let category: String?
  let address: String?
}

struct Reply: Encodable {
  let places: [Place]
}

struct ErrorReply: Encodable {
  struct Body: Encodable { let message: String }
  let error: Body
}

let maxRequestBytes = 65_536
let deadlineSeconds = 12.0
let maxRadiusMeters = 50_000.0
let maxErrorChainDepth = 4
// GEOErrorDomain -3 is the geocoder's and MapKit's throttle; CLGeocoder reports
// it as kCLErrorNetwork with this as its underlying error.
let geoErrorDomain = "GEOErrorDomain"
let geoThrottled = -3

func emit<T: Encodable>(_ value: T) {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
  FileHandle.standardOutput.write(data)
  FileHandle.standardOutput.write(Data("\n".utf8))
}

func fail(_ failure: Failure, _ message: String) -> Never {
  emit(ErrorReply(error: .init(message: message)))
  exit(failure.rawValue)
}

func succeed(_ places: [Place]) -> Never {
  emit(Reply(places: places))
  exit(0)
}

// MARK: - The request

func readRequest() -> SearchRequest {
  guard let line = readLine(strippingNewline: true) else {
    fail(.usage, "no request on stdin")
  }
  guard line.utf8.count <= maxRequestBytes else {
    fail(.usage, "the request is over \(maxRequestBytes) bytes")
  }
  guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
    let fields = object as? [String: Any]
  else {
    fail(.usage, "the request is not one JSON object")
  }
  guard Set(fields.keys) == ["query", "anchor"] else {
    fail(.usage, "the request takes exactly query and anchor")
  }
  return SearchRequest(query: query(fields["query"]), anchor: anchor(fields["anchor"]))
}

func query(_ value: Any?) -> String {
  guard let text = value as? String,
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  else {
    fail(.usage, "query must be a non-blank string")
  }
  return text
}

func anchor(_ value: Any?) -> Anchor {
  guard let fields = value as? [String: Any], let kind = fields["kind"] as? String else {
    fail(.usage, "anchor must be an object with a kind")
  }
  switch kind {
  case "query_only":
    exactKeys(fields, ["kind"])
    return .queryOnly
  case "location":
    exactKeys(fields, ["kind", "location"])
    return .location(query(fields["location"]))
  case "coordinates":
    exactKeys(fields, ["kind", "latitude", "longitude", "radius_meters"])
    return coordinates(fields)
  default:
    fail(.usage, "anchor kind must be query_only, location or coordinates")
  }
}

func exactKeys(_ fields: [String: Any], _ keys: Set<String>) {
  guard Set(fields.keys) == keys else {
    fail(.usage, "this anchor takes exactly \(keys.sorted().joined(separator: ", "))")
  }
}

func coordinates(_ fields: [String: Any]) -> Anchor {
  guard let latitude = number(fields["latitude"]), let longitude = number(fields["longitude"]),
    (-90.0...90.0).contains(latitude), (-180.0...180.0).contains(longitude)
  else {
    fail(.usage, "latitude must be -90..90 and longitude -180..180")
  }
  guard let radius = number(fields["radius_meters"]), radius >= 1, radius <= maxRadiusMeters
  else {
    fail(.usage, "radius_meters must be 1..\(Int(maxRadiusMeters))")
  }
  let center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
  return .coordinates(center, radius)
}

// JSONSerialization reads a JSON boolean as an NSNumber too, so it is refused
// by its type rather than read as 0 or 1.
func number(_ value: Any?) -> Double? {
  guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
    return nil
  }
  return number.doubleValue
}

// MARK: - The search

func search(_ request: SearchRequest) {
  switch request.anchor {
  case .queryOnly:
    run(request.query, region: nil)
  case .coordinates(let center, let radius):
    run(request.query, region: region(center, radius))
  case .location(let location):
    geocode(location) { region in run(request.query, region: region) }
  }
}

func region(_ center: CLLocationCoordinate2D, _ radius: CLLocationDistance) -> MKCoordinateRegion {
  MKCoordinateRegion(center: center, latitudinalMeters: radius * 2, longitudinalMeters: radius * 2)
}

// The placemark's own region sizes the search. A placemark with a position and
// no circular region is searched within the coordinates' default radius, the
// one the engine sends for coordinates; one with no position found nothing.
func geocode(_ location: String, then: @escaping (MKCoordinateRegion) -> Void) {
  CLGeocoder().geocodeAddressString(location) { placemarks, error in
    if let error, (placemarks ?? []).isEmpty { geocodeFailed(error) }

    guard let placemark = placemarks?.first, let position = placemark.location else {
      fail(.notFound, "the geocoder found no place for the location")
    }

    if let circle = placemark.region as? CLCircularRegion {
      then(region(circle.center, circle.radius))
    } else {
      then(region(position.coordinate, 5_000))
    }
  }
}

func geocodeFailed(_ error: Error) -> Never {
  let nsError = error as NSError

  if nsError.domain == kCLErrorDomain && nsError.code == CLError.geocodeFoundNoResult.rawValue {
    fail(.notFound, "the geocoder found no place for the location")
  }
  failed(error)
}

func run(_ query: String, region: MKCoordinateRegion?) {
  let request = MKLocalSearch.Request()
  request.naturalLanguageQuery = query
  request.resultTypes = .pointOfInterest
  if let region { request.region = region }

  MKLocalSearch(request: request).start { response, error in
    if let error { searchFailed(error) }
    succeed((response?.mapItems ?? []).map(place))
  }
}

// MapKit answers a search that matched nothing with placemarkNotFound, which
// is an empty result, not a failure.
func searchFailed(_ error: Error) -> Never {
  let nsError = error as NSError

  if nsError.domain == MKErrorDomain && nsError.code == Int(MKError.placemarkNotFound.rawValue) {
    succeed([])
  }
  failed(error)
}

func failed(_ error: Error) -> Never {
  let chain = errorChain(error as NSError)
  let words = chain.map { "\($0.domain) \($0.code): \($0.localizedDescription)" }
    .joined(separator: "; ")

  if chain.contains(where: throttled) { fail(.throttled, words) }
  if chain.contains(where: offline) { fail(.network, words) }
  fail(.failed, words)
}

func errorChain(_ error: NSError) -> [NSError] {
  var chain = [error]
  while chain.count < maxErrorChainDepth,
    let underlying = chain.last?.userInfo[NSUnderlyingErrorKey] as? NSError
  {
    chain.append(underlying)
  }
  return chain
}

func throttled(_ error: NSError) -> Bool {
  (error.domain == MKErrorDomain && error.code == Int(MKError.loadingThrottled.rawValue))
    || (error.domain == geoErrorDomain && error.code == geoThrottled)
}

func offline(_ error: NSError) -> Bool {
  error.domain == NSURLErrorDomain
    || (error.domain == kCLErrorDomain && error.code == CLError.network.rawValue)
}

// MARK: - A result's raw fields

func place(_ item: MKMapItem) -> Place {
  let placemark = item.placemark
  let coordinate = placemark.coordinate
  let valid = CLLocationCoordinate2DIsValid(coordinate)

  return Place(
    name: item.name,
    latitude: valid ? coordinate.latitude : nil,
    longitude: valid ? coordinate.longitude : nil,
    identifier: item.identifier?.rawValue,
    url: item.url?.absoluteString,
    phone: item.phoneNumber,
    category: item.pointOfInterestCategory?.rawValue,
    address: placemark.title
  )
}

// MARK: - Main

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments == ["--check"] {
  print("fermix-maps: ok")
  exit(0)
}

guard arguments.isEmpty else { fail(.usage, "usage: fermix-maps [--check]") }

let request = readRequest()

DispatchQueue.main.asyncAfter(deadline: .now() + deadlineSeconds) {
  fail(.timedOut, "Apple Maps did not answer within \(Int(deadlineSeconds)) seconds")
}

DispatchQueue.main.async { search(request) }
dispatchMain()
