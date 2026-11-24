package com.tzglasses.hud

import android.app.Application
import android.content.Context
import android.graphics.Bitmap
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.tzglasses.hud.core.DemoFeed
import com.tzglasses.hud.core.HudBuilder
import com.tzglasses.hud.core.HudFrame
import com.tzglasses.hud.core.HudSettings
import com.tzglasses.hud.core.Severity
import com.tzglasses.hud.data.BridgeClient
import com.tzglasses.hud.glasses.GlassesController
import com.tzglasses.hud.glasses.GlassesGesture
import com.tzglasses.hud.glasses.LensMode
import com.tzglasses.hud.head.HeadSource
import com.tzglasses.hud.head.HeadTracker
import com.tzglasses.hud.render.HudBitmapRenderer
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Runs the loop: boat data + head direction -> HudFrame -> phone preview and glasses.
 * Sends to the glasses only when the picture changes (or a 2 s heartbeat), never overlapping,
 * and no faster than the rate set in Settings. Port of AppModel.swift.
 */
class AppViewModel(app: Application) : AndroidViewModel(app) {
  private val prefs = app.getSharedPreferences("settings", Context.MODE_PRIVATE)

  val bridge = BridgeClient(viewModelScope)
  val head = HeadTracker(app)
  val glasses = GlassesController(app, viewModelScope)

  // Settings (saved between launches)
  var bridgeAddress by mutableStateOf(prefs.getString("bridgeAddress", "") ?: ""); private set
  var useDemoData by mutableStateOf(prefs.getBoolean("useDemoData", true)); private set
  var lensMode by mutableStateOf(LensMode.entries.firstOrNull { it.name == prefs.getString("lensMode", null) } ?: LensMode.PICTURE); private set
  var maxUpdatesPerSecond by mutableStateOf(prefs.getFloat("maxUpdatesPerSecond", 4f).toDouble()); private set
  var hud by mutableStateOf(HudSettings(
      fovDeg = prefs.getFloat("fovDeg", 20f).toDouble(),
      cpaCautionNm = prefs.getFloat("cpaCautionNm", 0.5f).toDouble(),
      cpaDangerNm = prefs.getFloat("cpaDangerNm", 0.25f).toDouble(),
      markRangeNm = prefs.getFloat("markRangeNm", 5f).toDouble(),
      showMarks = prefs.getBoolean("showMarks", true),
      hiddenSources = prefs.getStringSet("hiddenSources", emptySet()) ?: emptySet(),
  )); private set

  var frame by mutableStateOf(HudFrame.WAITING); private set
  var preview by mutableStateOf<Bitmap?>(null); private set

  private val demo = DemoFeed()
  private var loop: Job? = null
  private var demoLoop: Job? = null
  private var lastSentFrame: HudFrame? = null
  private var lastSentAt = 0L
  private var lastPreviewAt = 0L
  private var previewFrame: HudFrame? = null
  private val ackExpiry = HashMap<String, Long>()

  init {
    head.reverseDirection = prefs.getBoolean("reverseDirection", false)
    HeadSource.entries.firstOrNull { it.name == prefs.getString("headSource", null) }?.let { head.select(it) }
    head.currentBoatHeading = { bridge.snapshot?.referenceHeading }
    glasses.onHeadSample = { head.ingestGlasses(it) }
    glasses.onGesture = ::handle
  }

  /** Call once Wearables.initialize() has run. */
  fun start() {
    if (loop != null) return
    glasses.startObserving()
    head.start()
    applyDataSource()
    loop = viewModelScope.launch {
      while (isActive) {
        tick()
        delay(50)
      }
    }
  }

  override fun onCleared() {
    head.stop()
    glasses.disconnect()
    bridge.disconnect()
  }

  // Settings setters (each saves)

  fun updateBridgeAddress(a: String) {
    bridgeAddress = a
    prefs.edit().putString("bridgeAddress", a).apply()
    if (!useDemoData) bridge.connect(a)
  }

  fun updateUseDemoData(on: Boolean) {
    useDemoData = on
    prefs.edit().putBoolean("useDemoData", on).apply()
    applyDataSource()
  }

  fun updateLensMode(m: LensMode) {
    lensMode = m
    prefs.edit().putString("lensMode", m.name).apply()
  }

  fun updateMaxUpdates(v: Double) {
    maxUpdatesPerSecond = v
    prefs.edit().putFloat("maxUpdatesPerSecond", v.toFloat()).apply()
  }

  fun updateHud(s: HudSettings) {
    hud = s
    prefs.edit()
        .putFloat("fovDeg", s.fovDeg.toFloat())
        .putFloat("cpaCautionNm", s.cpaCautionNm.toFloat())
        .putFloat("cpaDangerNm", s.cpaDangerNm.toFloat())
        .putFloat("markRangeNm", s.markRangeNm.toFloat())
        .putBoolean("showMarks", s.showMarks)
        .putStringSet("hiddenSources", s.hiddenSources)
        .apply()
  }

  fun updateHeadSource(src: HeadSource) {
    head.select(src)
    prefs.edit().putString("headSource", src.name).apply()
  }

  fun updateReverseDirection(on: Boolean) {
    head.reverseDirection = on
    prefs.edit().putBoolean("reverseDirection", on).apply()
  }

  private fun applyDataSource() {
    demoLoop?.cancel()
    demoLoop = null
    if (useDemoData) {
      bridge.disconnect()
      demo.reset()
      demoLoop = viewModelScope.launch {
        while (isActive) {
          // Run the demo at 10x so things happen while you watch.
          bridge.inject(demo.step(5.0))
          delay(500)
        }
      }
    } else {
      bridge.connect(bridgeAddress)
    }
  }

  // Gestures

  fun handle(g: GlassesGesture) {
    when (g) {
      // A tap while an alarm shows acknowledges it; otherwise it re-centres.
      GlassesGesture.RECENTER -> if (frame.alarmTitle != null) acknowledgeAlarm() else head.recenter()
      GlassesGesture.ACKNOWLEDGE -> acknowledgeAlarm()
      GlassesGesture.NUDGE_LEFT -> head.nudge(-2.0)
      GlassesGesture.NUDGE_RIGHT -> head.nudge(2.0)
    }
  }

  /** Silences the current alarm for 2 minutes (it comes back if the situation persists). */
  fun acknowledgeAlarm() {
    val snap = bridge.snapshot ?: return
    val until = System.currentTimeMillis() + 120_000
    for (t in snap.targets ?: emptyList()) {
      if (HudBuilder.severity(t, hud) != Severity.NORMAL) ackExpiry[t.key] = until
    }
  }

  // Loop

  private suspend fun tick() {
    val now = System.currentTimeMillis()
    ackExpiry.entries.removeAll { it.value <= now }
    val snap = bridge.snapshot
    val gaze = head.gaze(snap?.referenceHeading)
    val f = HudBuilder.build(snap, gaze, hud, ackExpiry.keys.toSet())
    frame = f

    if (preview == null || (f != previewFrame && now - lastPreviewAt > 100)) {
      preview = HudBitmapRenderer.render(f)
      previewFrame = f
      lastPreviewAt = now
    }

    val minIntervalMs = 1000.0 / maxUpdatesPerSecond.coerceAtLeast(0.5)
    if (!glasses.canSend || now - lastSentAt < minIntervalMs) return
    if (f == lastSentFrame && now - lastSentAt <= 2000) return
    lastSentFrame = f
    lastSentAt = now
    val image = if (lensMode == LensMode.PICTURE) (if (previewFrame == f) preview else null) ?: HudBitmapRenderer.render(f) else null
    val mode = lensMode
    viewModelScope.launch { glasses.send(f, mode, image) }
  }
}
