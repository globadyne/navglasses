package com.tzglasses.hud.core

/**
 * Models for the JSON that tz_bridge.py serves at /state.json and streams on /ws
 * (same as BoatData.swift on iOS). Every field is optional: the bridge drops values that stop
 * updating, so a missing field means "no data", never zero.
 */
data class OwnShip(
    val lat: Double? = null,
    val lon: Double? = null,
    val sog: Double? = null,
    val cog: Double? = null,
    val hdg: Double? = null,
    val rot: Double? = null,
    val depthM: Double? = null,
    val aws: Double? = null,
    val awa: Double? = null,
    val waterTempC: Double? = null,
)

data class Waypoint(
    val name: String? = null,
    val lat: Double? = null,
    val lon: Double? = null,
    val rangeNm: Double? = null,
    val bearing: Double? = null,
)

data class RouteInfo(
    val toWp: String? = null,
    val fromWp: String? = null,
    val rangeNm: Double? = null,
    val bearing: Double? = null,
    val xteNm: Double? = null,
    val steer: String? = null,
    val routeName: String? = null,
    val nextIndex: Int? = null,
    val waypoints: List<Waypoint>? = null,
)

data class Target(
    val mmsi: Long? = null,
    val name: String? = null,
    val kind: String? = null,       // "vessel" or "aton"
    val typeLabel: String? = null,  // "Cargo", "Sailing"... (raw AIS only)
    val source: String? = null,     // "AIS", "ARPA" (radar) or "TTM"
    val lat: Double? = null,
    val lon: Double? = null,
    val sog: Double? = null,
    val cog: Double? = null,
    val rangeNm: Double? = null,
    val bearing: Double? = null,
    val cpaNm: Double? = null,
    val tcpaMin: Double? = null,
) {
  /** Stable key for alarm acknowledgement. */
  val key: String get() = mmsi?.toString() ?: name ?: "${lat ?: 0},${lon ?: 0}"
  val isVessel: Boolean get() = kind != "aton"
}

data class Mark(
    val name: String? = null,
    val note: String? = null,
    val lat: Double? = null,
    val lon: Double? = null,
    val rangeNm: Double? = null,
    val bearing: Double? = null,
)

data class BoatSnapshot(
    val time: Double? = null,
    val rxAgeS: Double? = null,
    val own: OwnShip? = null,
    val route: RouteInfo? = null,
    val targets: List<Target>? = null,
    val marks: List<Mark>? = null,
) {
  /** Heading to place things around the boat: true heading, else COG. */
  val referenceHeading: Double? get() = own?.hdg ?: own?.cog

  companion object {
    /** Parses one bridge message. Throws on malformed JSON. */
    fun parse(json: String): BoatSnapshot {
      @Suppress("UNCHECKED_CAST")
      val m = Json.parse(json) as? Map<String, Any?> ?: error("Not a JSON object")
      return BoatSnapshot(
          time = m.dbl("time"),
          rxAgeS = m.dbl("rx_age_s"),
          own = m.obj("own")?.let { o ->
            OwnShip(o.dbl("lat"), o.dbl("lon"), o.dbl("sog"), o.dbl("cog"), o.dbl("hdg"), o.dbl("rot"),
                o.dbl("depth_m"), o.dbl("aws"), o.dbl("awa"), o.dbl("water_temp_c"))
          },
          route = m.obj("route")?.let { r ->
            RouteInfo(
                toWp = r.str("to_wp"), fromWp = r.str("from_wp"), rangeNm = r.dbl("range_nm"),
                bearing = r.dbl("bearing"), xteNm = r.dbl("xte_nm"), steer = r.str("steer"),
                routeName = r.str("route_name"), nextIndex = r.int("next_index"),
                waypoints = r.objs("waypoints")?.map { w ->
                  Waypoint(w.str("name"), w.dbl("lat"), w.dbl("lon"), w.dbl("range_nm"), w.dbl("bearing"))
                },
            )
          },
          targets = m.objs("targets")?.map { t ->
            Target(
                mmsi = t.long("mmsi"), name = t.str("name"), kind = t.str("kind"),
                typeLabel = t.str("type_label"), source = t.str("source"), lat = t.dbl("lat"),
                lon = t.dbl("lon"), sog = t.dbl("sog"), cog = t.dbl("cog"), rangeNm = t.dbl("range_nm"),
                bearing = t.dbl("bearing"), cpaNm = t.dbl("cpa_nm"), tcpaMin = t.dbl("tcpa_min"),
            )
          },
          marks = m.objs("marks")?.map { k ->
            Mark(k.str("name"), k.str("note"), k.dbl("lat"), k.dbl("lon"), k.dbl("range_nm"), k.dbl("bearing"))
          },
      )
    }
  }
}
