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
  var source: String?      // "TTM" when it came from TimeZero 4's tracked targets
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
  var lat: Double?
  var lon: Double?
  var rangeNm: Double?
  var bearing: Double?
}
