package com.tzglasses.hud.head

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.tzglasses.hud.core.Geo
import com.tzglasses.hud.core.HeadMath
import com.tzglasses.hud.core.HeadSample
import com.tzglasses.hud.core.Quat
import com.tzglasses.hud.core.Vec3

enum class HeadSource(val label: String) { GLASSES("Glasses"), PHONE("Phone"), MANUAL("Slider") }

/**
 * Works out the true bearing the wearer is looking at (port of HeadTracker.swift):
 *
 *   gaze = boat heading when calibrated + head turn since calibration + fine tune
 *
 * The heading at calibration (not the live one) is deliberate: the glasses measure against the
 * world, so when the boat turns under a still head, labels stay on their targets.
 *
 * Sources: the glasses' Motion samples; the phone's own sensors (hold it up like a viewfinder to
 * test at a desk); or a slider.
 */
class HeadTracker(context: Context) : SensorEventListener {
  var source by mutableStateOf(HeadSource.GLASSES); private set
  /** Slider value for MANUAL, degrees from the bow (negative = port). */
  var manualTurnDeg by mutableDoubleStateOf(0.0)
  /** Correction the wearer adds by swiping (degrees, positive = starboard). */
  var fineTuneDeg by mutableDoubleStateOf(0.0)
  var reverseDirection by mutableStateOf(false)

  var headTurnDeg by mutableStateOf<Double?>(null); private set
  var status by mutableStateOf("Waiting for motion data"); private set
  var samplesPerSecond by mutableDoubleStateOf(0.0); private set

  /** Supplies the boat's current heading when it is known. */
  var currentBoatHeading: () -> Double? = { null }

  private var math = HeadMath()
  private var headingAtCalibration: Double? = null
  private var pendingCalibration = true
  private var rateCount = 0
  private var rateWindowStart = System.nanoTime()

  private val sensors = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
  private var gravity: Vec3? = null
  private var gyro: Vec3? = null

  fun gaze(boatHeading: Double?): Double? = when (source) {
    HeadSource.MANUAL -> boatHeading?.let { Geo.wrap360(it + manualTurnDeg + fineTuneDeg) }
    else -> headTurnDeg?.let { turn ->
      // Calibrated before the boat's heading arrived: assume the boat hasn't turned since.
      if (headingAtCalibration == null) headingAtCalibration = boatHeading
      val base = headingAtCalibration ?: boatHeading ?: 0.0
      Geo.wrap360(base + (if (reverseDirection) -turn else turn) + fineTuneDeg)
    }
  }

  /** Head turn relative to the bow right now (for the phone UI), degrees. */
  fun turnFromBow(boatHeading: Double?): Double? {
    val g = gaze(boatHeading)
    if (g == null || boatHeading == null) return if (source == HeadSource.MANUAL) manualTurnDeg else headTurnDeg
    return Geo.wrap180(g - boatHeading)
  }

  /** "I'm looking at the bow now." */
  fun recenter() {
    fineTuneDeg = 0.0
    if (source == HeadSource.MANUAL) { manualTurnDeg = 0.0; return }
    headingAtCalibration = currentBoatHeading()
    math.calibrate()
    pendingCalibration = !math.isCalibrated
    headTurnDeg = if (math.isCalibrated) 0.0 else null
    status = if (math.isCalibrated) "Tracking" else "Waiting for motion data"
  }

  fun nudge(deg: Double) { fineTuneDeg += deg }

  /** Feed a sample from the glasses (via GlassesController). Main thread. */
  fun ingestGlasses(sample: HeadSample) {
    if (source == HeadSource.GLASSES) ingest(sample)
  }

  private fun ingest(sample: HeadSample) {
    val turn = math.ingest(sample)
    if (pendingCalibration) recenter()   // first samples: assume the wearer faces the bow
    else headTurnDeg = turn
    rateCount++
    val now = System.nanoTime()
    val elapsed = (now - rateWindowStart) / 1e9
    if (elapsed >= 1) {
      samplesPerSecond = rateCount / elapsed
      rateCount = 0
      rateWindowStart = now
    }
  }

  fun select(newSource: HeadSource) {
    if (newSource == source) return
    source = newSource
    start()
  }

  /** Starts whichever source is selected. Call once at launch. */
  fun start() {
    sensors.unregisterListener(this)
    math = HeadMath()
    headTurnDeg = null
    pendingCalibration = true
    fineTuneDeg = 0.0
    samplesPerSecond = 0.0
    when (source) {
      HeadSource.MANUAL -> status = "Using the slider"
      HeadSource.GLASSES -> status = "Waiting for motion data from the glasses"
      HeadSource.PHONE -> startPhone()
    }
  }

  fun stop() = sensors.unregisterListener(this)

  private fun startPhone() {
    // Game rotation vector: gyro + accelerometer, no magnetometer, so steel hulls and engines
    // don't pull it around. Its world frame has z up, like the glasses' convention we detect.
    val rot = sensors.getDefaultSensor(Sensor.TYPE_GAME_ROTATION_VECTOR)
    if (rot == null) { status = "This phone has no motion sensors"; return }
    status = "Using the phone's motion sensors"
    val period = 33_333 // µs, 30 Hz
    sensors.registerListener(this, rot, period)
    sensors.getDefaultSensor(Sensor.TYPE_GRAVITY)?.let { sensors.registerListener(this, it, period) }
    sensors.getDefaultSensor(Sensor.TYPE_GYROSCOPE)?.let { sensors.registerListener(this, it, period) }
  }

  override fun onSensorChanged(e: SensorEvent) {
    if (source != HeadSource.PHONE) return
    when (e.sensor.type) {
      // Android's gravity sensor reads like an accelerometer at rest (+z when flat, face up).
      Sensor.TYPE_GRAVITY -> gravity = Vec3(e.values[0].toDouble(), e.values[1].toDouble(), e.values[2].toDouble())
      Sensor.TYPE_GYROSCOPE -> gyro = Vec3(e.values[0].toDouble(), e.values[1].toDouble(), e.values[2].toDouble())
      Sensor.TYPE_GAME_ROTATION_VECTOR -> {
        val q = FloatArray(4)
        SensorManager.getQuaternionFromVector(q, e.values) // w, x, y, z; device -> world
        ingest(HeadSample(e.timestamp, Quat(q[0].toDouble(), q[1].toDouble(), q[2].toDouble(), q[3].toDouble()),
            gravity, gyro))
      }
    }
  }

  override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
}
