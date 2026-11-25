//
// BoatData.swift
//
// Models for the JSON that tz_bridge.py serves at /state.json and streams on /ws.
// Every field is optional: the bridge drops values that stop updating, so a
// missing field means "no data", never zero.
//

import Foundation

struct BoatSnapshot: Decodable, Sendable {
  var time: Double?
  var rxAgeS: Double?
  var own: OwnShip?
  var route: RouteInfo?
  var targets: [Target]?
  var marks: [Mark]?
  /// Changes when the bridge reloads marks, routes or tracks (fetch /userdata.json again).
  var userdataVersion: Double?

  static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }()

  /// Heading to use for placing things around the boat: true heading, else COG.
  var referenceHeading: Double? { own?.hdg ?? own?.cog }
}

struct OwnShip: Decodable, Sendable {
  var lat: Double?
  var lon: Double?
  var sog: Double?
  var cog: Double?
  var hdg: Double?
  var rot: Double?
  var depthM: Double?
  var aws: Double?
  var awa: Double?
  var waterTempC: Double?
}

struct RouteInfo: Decodable, Sendable {
  var toWp: String?
  var fromWp: String?
  var rangeNm: Double?
  var bearing: Double?
  var xteNm: Double?
  var steer: String?
  var routeName: String?
  var nextIndex: Int?
  var waypoints: [Waypoint]?
}

struct Waypoint: Decodable, Sendable {
  var name: String?
  var lat: Double?
  var lon: Double?
  var rangeNm: Double?
  var bearing: Double?
}

struct Target: Decodable, Sendable {
  var mmsi: Int?
  var name: String?
  var kind: String?        // "vessel" or "aton"
  var typeLabel: String?   // "Cargo", "Sailing"... (raw AIS only, not TTM)
  var source: String?      // "AIS", "ARPA", "TTM", or "ONLINE" for internet AIS (TimeZero 5)
  /// Seconds since the last position report. Online AIS can be minutes old.
  var ageS: Double?
  var lat: Double?
  var lon: Double?
  var sog: Double?
  var cog: Double?
  var rangeNm: Double?
  var bearing: Double?
  var cpaNm: Double?
  var tcpaMin: Double?

  /// Stable key for alarm acknowledgement.
  var key: String { mmsi.map(String.init) ?? name ?? "\(lat ?? 0),\(lon ?? 0)" }
  var isVessel: Bool { kind != "aton" }
}

struct Mark: Decodable, Sendable {
  var name: String?
  var note: String?
  /// GPX `<sym>` (e.g. "Fishing Area"), when the mark came from a GPX file.
  var symbol: String?
  /// TimeZero's icon: a number from UserObjects.tzdb, or a name from the demo.
  var icon: LooseString?
  var lat: Double?
  var lon: Double?
  var rangeNm: Double?
  var bearing: Double?
  /// TimeZero's id for the mark (UserObjects.tzdb Guid), when it came from the database.
  var id: String?
  /// TimeZero's colour number (not mapped to a colour yet; 11 = orange).
  var color: LooseString?

  /// Identifies the mark for acknowledging its alarm.
  var key: String { "mark:" + (id ?? name ?? "\(lat ?? 0),\(lon ?? 0)") }
}

/// A JSON value that may arrive as a string or a number; kept as text.
struct LooseString: Decodable, Sendable, ExpressibleByStringLiteral {
  var value: String
  init(stringLiteral value: String) { self.value = value }
  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if let s = try? c.decode(String.self) { value = s }
    else if let i = try? c.decode(Int.self) { value = String(i) }
    else { value = String(try c.decode(Double.self)) }
  }
}

/// A point of a recorded or saved track. `t` is seconds since 1970, when known.
struct TrackPoint: Codable, Equatable, Sendable {
  var lat: Double
  var lon: Double
  var t: Double?
}

struct SavedTrack: Decodable, Sendable {
  var name: String?
  var points: [TrackPoint]
}

/// What tz_bridge.py serves at /userdata.json. Only the tracks are used here; marks and
/// routes already arrive in the live stream.
struct UserData: Decodable, Sendable {
  var version: Double?
  var tracks: [SavedTrack]?
  var ownTrack: [TrackPoint]?
}
