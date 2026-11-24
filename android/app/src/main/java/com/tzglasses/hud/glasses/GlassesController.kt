package com.tzglasses.hud.glasses

import android.app.Activity
import android.content.Context
import android.graphics.Bitmap
import android.view.View
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.meta.wearable.dat.core.Wearables
import com.meta.wearable.dat.core.selectors.AutoDeviceSelector
import com.meta.wearable.dat.core.session.DeviceSession
import com.meta.wearable.dat.core.session.DeviceSessionState
import com.meta.wearable.dat.core.types.DeviceSessionError
import com.meta.wearable.dat.core.types.RegistrationState
import com.meta.wearable.dat.display.Display
import com.meta.wearable.dat.display.addDisplay
import com.meta.wearable.dat.display.removeDisplay
import com.meta.wearable.dat.display.types.DisplayState
import com.meta.wearable.dat.inputs.Inputs
import com.meta.wearable.dat.inputs.addInputs
import com.meta.wearable.dat.inputs.removeInputs
import com.meta.wearable.dat.inputs.types.InputEvent
import com.meta.wearable.dat.inputs.types.InputsConfiguration
import com.meta.wearable.dat.inputs.types.NavDirection
import com.meta.wearable.dat.mockdevice.MockDeviceKit
import com.meta.wearable.dat.mockdevice.api.GlassesModel
import com.meta.wearable.dat.mockdevice.api.MockGlasses
import com.meta.wearable.dat.motion.Motion
import com.meta.wearable.dat.motion.addMotion
import com.meta.wearable.dat.motion.removeMotion
import com.meta.wearable.dat.motion.types.MotionConfiguration
import com.meta.wearable.dat.motion.types.MotionSamplingRate
import com.meta.wearable.dat.motion.types.MotionSource
import com.tzglasses.hud.core.HeadSample
import com.tzglasses.hud.core.HudFrame
import com.tzglasses.hud.core.Quat
import com.tzglasses.hud.core.Vec3
import com.tzglasses.hud.glasses.HudDisplayLayout.picture
import com.tzglasses.hud.glasses.HudDisplayLayout.text
import com.tzglasses.hud.render.HudBitmapRenderer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

enum class GlassesGesture { RECENTER, NUDGE_LEFT, NUDGE_RIGHT, ACKNOWLEDGE }

/**
 * Everything that talks to the Ray-Ban Display through Meta's Wearables Device Access Toolkit
 * (Android SDK 1.1.0), following Meta's DisplayAccess and BirdSpotter samples:
 * registration, the device session, Display, Motion (experimental), Inputs (experimental) and
 * simulated glasses (MockDeviceKit). Port of GlassesController.swift.
 *
 * Lifecycle: create session -> start -> wait for STARTED -> add capabilities -> wait for
 * DisplayState.STARTED before sending. All state is touched on the main thread.
 */
class GlassesController(private val context: Context, private val scope: CoroutineScope) {
  sealed class Phase {
    data object Idle : Phase()
    data object Connecting : Phase()
    data object Connected : Phase()
    data class Failed(val reason: String) : Phase()
  }

  var registration by mutableStateOf<RegistrationState>(RegistrationState.UNAVAILABLE); private set
  var phase by mutableStateOf<Phase>(Phase.Idle); private set
  var motionStatus by mutableStateOf("Not started"); private set
  var inputsStatus by mutableStateOf("Not started"); private set
  var requiresGlassesAppUpdate by mutableStateOf(false); private set
  var simulated by mutableStateOf(false); private set
  /** The simulated glasses, whose display preview the UI shows. */
  var mockGlasses by mutableStateOf<MockGlasses?>(null); private set

  var lastSendMs by mutableDoubleStateOf(0.0); private set
  var updatesPerSecond by mutableDoubleStateOf(0.0); private set
  var lastSendError by mutableStateOf<String?>(null); private set

  val isConnected get() = phase == Phase.Connected
  val isRegistered get() = registration == RegistrationState.REGISTERED

  var onHeadSample: (HeadSample) -> Unit = {}
  var onGesture: (GlassesGesture) -> Unit = {}

  private var session: DeviceSession? = null
  private var display: Display? = null
  private var motion: Motion? = null
  private var inputs: Inputs? = null
  private var displayReady = false
  private var sending = false
  private val jobs = ArrayList<Job>()
  private val sendTimes = ArrayDeque<Long>()
  private var started = false

  /** Call after Wearables.initialize(). */
  fun startObserving() {
    if (started) return
    started = true
    scope.launch {
      Wearables.registrationState.collect { state ->
        registration = state
        if (state != RegistrationState.REGISTERED && session != null && !simulated) disconnect()
      }
    }
  }

  // Registration

  fun register(activity: Activity) {
    if (!isRegistered) Wearables.startRegistration(activity)
  }

  fun openGlassesAppUpdate(activity: Activity) = Wearables.openDATGlassesAppUpdate(activity)

  // Simulated glasses

  /** Pairs a simulated Ray-Ban Display so the whole app can be tested without hardware. */
  fun useSimulatedGlasses(on: Boolean) {
    disconnect()
    val kit = MockDeviceKit.getInstance(context)
    if (on) {
      kit.enable()
      kit.pairGlasses(GlassesModel.META_RAYBAN_DISPLAY).fold(
          onSuccess = { g ->
            g.powerOn()
            g.don()
            mockGlasses = g
            simulated = true
          },
          onFailure = { error, _ -> phase = Phase.Failed("Couldn't create simulated glasses: ${error.description}") },
      )
    } else {
      mockGlasses?.let { it.doff(); it.powerOff() }
      mockGlasses = null
      simulated = false
      kit.disable()
    }
  }

  /** The simulated glasses' own rendering of what we sent. */
  fun createSimulatedPreview(ctx: Context): View? = mockGlasses?.services?.display?.createPreviewView(ctx)

  // Connect

  fun connect() {
    if (session != null) return
    phase = Phase.Connecting
    requiresGlassesAppUpdate = false
    Wearables.createSession(AutoDeviceSelector(filter = { it.isDisplayCapable() })).fold(
        onSuccess = { s ->
          session = s
          jobs += scope.launch {
            s.state.collect { state ->
              when (state) {
                DeviceSessionState.STARTED -> attachCapabilities(s)
                DeviceSessionState.STOPPED -> teardown()
                else -> {}
              }
            }
          }
          jobs += scope.launch {
            s.errors.collect { error ->
              if (error == DeviceSessionError.DAT_APP_ON_THE_GLASSES_UPDATE_REQUIRED) requiresGlassesAppUpdate = true
              phase = Phase.Failed(error.description)
            }
          }
          s.start()
          // Don't wait forever if the glasses are off or out of range.
          jobs += scope.launch {
            delay(15_000)
            if (phase == Phase.Connecting) {
              disconnect()
              phase = Phase.Failed("Glasses didn't respond. Check they're on, worn and connected in Meta AI.")
            }
          }
        },
        onFailure = { error, _ ->
          teardown()
          phase = when (error) {
            DeviceSessionError.DAT_APP_ON_THE_GLASSES_UPDATE_REQUIRED -> {
              requiresGlassesAppUpdate = true
              Phase.Failed("The glasses need an update in the Meta AI app.")
            }
            DeviceSessionError.NOT_REGISTERED -> Phase.Failed("Register with Meta AI first.")
            else -> Phase.Failed("Couldn't connect: ${error.description}")
          }
        },
    )
  }

  fun disconnect() {
    val s = session
    if (s != null) {
      runCatching { motion?.stop() }
      runCatching { s.removeMotion() }
      runCatching { s.removeInputs() }
      runCatching { s.removeDisplay() }
      runCatching { s.stop() }
    }
    teardown()
  }

  private fun teardown() {
    jobs.forEach { it.cancel() }
    jobs.clear()
    display = null
    motion = null
    inputs = null
    session = null
    displayReady = false
    sending = false
    motionStatus = "Not started"
    inputsStatus = "Not started"
    if (phase !is Phase.Failed) phase = Phase.Idle
  }

  private fun attachCapabilities(s: DeviceSession) {
    if (display == null) {
      s.addDisplay().fold(
          onSuccess = { d ->
            display = d
            jobs += scope.launch {
              d.state.collect { state ->
                when (state) {
                  DisplayState.STARTED -> { displayReady = true; phase = Phase.Connected }
                  DisplayState.STOPPED -> { displayReady = false; if (phase == Phase.Connected) phase = Phase.Idle }
                  else -> {}
                }
              }
            }
          },
          onFailure = { error, _ -> phase = Phase.Failed("Couldn't open the display: ${error.description}") },
      )
      if (display == null) return
    }

    // Motion (experimental): head orientation. Unlike inputs it must be started.
    if (motion == null) {
      s.addMotion(MotionConfiguration(samplingRate = MotionSamplingRate.HZ_30)).fold(
          onSuccess = { m ->
            motion = m
            jobs += scope.launch { m.state.collect { motionStatus = it.toString().lowercase().replaceFirstChar(Char::uppercase) } }
            jobs += scope.launch { m.errors.collect { e -> if (e != null) motionStatus = e.description } }
            jobs += scope.launch {
              // One motion feed can carry the glasses and the Neural Band: two bodies moving
              // independently. Only the head counts. Unlabelled samples are used only while no
              // glasses-labelled sample has arrived in the last 2 s (BirdSpotter keeps GLASSES only).
              var lastGlasses = 0L
              m.samples.collect { sample ->
                val now = System.currentTimeMillis()
                when {
                  sample.source == MotionSource.GLASSES -> lastGlasses = now
                  sample.source.toString().contains("NEURAL", ignoreCase = true) -> return@collect
                  now - lastGlasses < 2000 -> return@collect
                }
                val q = sample.orientation ?: return@collect
                onHeadSample(HeadSample(
                    timestampNs = sample.timestampNs,
                    orientation = Quat(q.w.toDouble(), q.x.toDouble(), q.y.toDouble(), q.z.toDouble()),
                    accelerometer = sample.accelerometer?.let { Vec3(it.x.toDouble(), it.y.toDouble(), it.z.toDouble()) },
                    gyroscope = sample.gyroscope?.let { Vec3(it.x.toDouble(), it.y.toDouble(), it.z.toDouble()) },
                ))
              }
            }
            m.start()
          },
          onFailure = { error, _ -> motionStatus = "Not enabled for this app (${error.description})" },
      )
    }

    // Inputs (experimental): gestures. Starts on its own once added.
    if (inputs == null) {
      s.addInputs(InputsConfiguration(consumeBack = false)).fold(
          onSuccess = { i ->
            inputs = i
            inputsStatus = "Active"
            jobs += scope.launch {
              i.events.collect { event ->
                when (event) {
                  is InputEvent.Select, is InputEvent.Button -> onGesture(GlassesGesture.RECENTER)
                  is InputEvent.Nav -> when (event.direction) {
                    NavDirection.LEFT -> onGesture(GlassesGesture.NUDGE_LEFT)
                    NavDirection.RIGHT -> onGesture(GlassesGesture.NUDGE_RIGHT)
                    else -> onGesture(GlassesGesture.ACKNOWLEDGE)
                  }
                  else -> {}
                }
              }
            }
            jobs += scope.launch { i.errors.collect { e -> if (e != null) inputsStatus = e.description } }
          },
          onFailure = { _, _ -> inputsStatus = "Not enabled for this app" },
      )
    }
  }

  // Sending

  /** True if a new frame can be sent now (connected and the previous send finished). */
  val canSend get() = displayReady && !sending && display != null

  suspend fun send(frame: HudFrame, mode: LensMode, image: Bitmap?) {
    val d = display ?: return
    if (!canSend) return
    sending = true
    val tap = { onGesture(GlassesGesture.RECENTER) }
    val t0 = System.nanoTime()
    try {
      val result = when (mode) {
        LensMode.PICTURE -> {
          val img = image ?: HudBitmapRenderer.render(frame)
          d.sendContent { picture(img, tap) }
        }
        LensMode.TEXT -> d.sendContent { text(frame, tap) }
      }
      result.fold(
          onSuccess = {
            lastSendError = null
            val ms = (System.nanoTime() - t0) / 1e6
            lastSendMs = if (lastSendMs == 0.0) ms else lastSendMs * 0.8 + ms * 0.2
            val now = System.currentTimeMillis()
            sendTimes.addLast(now)
            while (sendTimes.isNotEmpty() && now - sendTimes.first() > 3000) sendTimes.removeFirst()
            updatesPerSecond = sendTimes.size / 3.0
          },
          onFailure = { error, _ -> lastSendError = error.description },
      )
    } finally {
      sending = false
    }
  }
}
