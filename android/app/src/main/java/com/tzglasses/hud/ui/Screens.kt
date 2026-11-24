package com.tzglasses.hud.ui

import android.app.Activity
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.tzglasses.hud.AppViewModel
import com.tzglasses.hud.core.fmt
import com.tzglasses.hud.data.BridgeClient
import com.tzglasses.hud.glasses.GlassesController.Phase
import com.tzglasses.hud.glasses.LensMode
import com.tzglasses.hud.head.HeadSource
import kotlin.math.abs
import kotlin.math.roundToInt

private val HudGreen = Color(0xFF8FF0C7)

@Composable
fun TZGlassesApp(model: AppViewModel) {
  MaterialTheme(colorScheme = darkColorScheme(primary = HudGreen, onPrimary = Color.Black)) {
    var showSettings by rememberSaveable { mutableStateOf(false) }
    Box(Modifier.fillMaxSize().background(Color.Black).safeDrawingPadding()) {
      if (showSettings) {
        BackHandler { showSettings = false }
        SettingsScreen(model, onDone = { showSettings = false })
      } else {
        MainScreen(model, onSettings = { showSettings = true })
      }
    }
  }
}

// Main screen: what the lens shows, connection status, head controls.

@Composable
private fun MainScreen(model: AppViewModel, onSettings: () -> Unit) {
  val g = model.glasses
  val head = model.head
  val activity = LocalContext.current as? Activity
  Column(
      Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
      verticalArrangement = Arrangement.spacedBy(20.dp),
  ) {
    Row(verticalAlignment = Alignment.CenterVertically) {
      Text("TZ Glasses", style = MaterialTheme.typography.headlineMedium, modifier = Modifier.weight(1f))
      TextButton(onClick = onSettings) { Text("Settings") }
    }

    // Lens
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
      Text("Lens view", style = MaterialTheme.typography.titleMedium)
      val shape = RoundedCornerShape(12.dp)
      Box(Modifier.fillMaxWidth().aspectRatio(1f).clip(shape).border(1.dp, Color.Gray.copy(alpha = 0.3f), shape)
          .background(Color.Black)) {
        model.preview?.let { Image(it.asImageBitmap(), contentDescription = "Lens preview", Modifier.fillMaxSize()) }
      }
      Caption("Black is see-through on the glasses.")
      val mock = g.mockGlasses
      if (g.simulated && mock != null) {
        Text("Simulated glasses (what was actually sent)", Modifier.padding(top = 8.dp))
        key(mock) {
          AndroidView(
              factory = { ctx -> g.createSimulatedPreview(ctx) ?: android.view.View(ctx) },
              modifier = Modifier.fillMaxWidth().aspectRatio(1f).clip(shape).background(Color.Black),
          )
        }
      }
    }

    // Status
    Card {
      Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        val failed = g.phase is Phase.Failed
        StatusRow("Glasses", glassesText(model), if (g.isConnected) Dot.GOOD else if (failed) Dot.BAD else Dot.WAIT)
        StatusRow("Head tracking", headText(model),
            if (head.headTurnDeg != null || head.source == HeadSource.MANUAL) Dot.GOOD else Dot.WAIT)
        val (boat, dot) = if (model.useDemoData) "Demo data (Halifax Harbour)" to Dot.GOOD else model.bridge.status.let {
          it.text to when (it) {
            BridgeClient.Status.Live -> Dot.GOOD
            BridgeClient.Status.Connecting, BridgeClient.Status.NoData -> Dot.WAIT
            else -> Dot.BAD
          }
        }
        StatusRow("Boat data", boat, dot)
      }
    }

    // Glasses
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
      Text("Glasses", style = MaterialTheme.typography.titleMedium)
      Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        when {
          !g.isRegistered && !g.simulated ->
            Button(onClick = { activity?.let(g::register) }) { Text("Register with Meta AI") }
          g.isConnected || g.phase == Phase.Connecting -> OutlinedButton(onClick = g::disconnect) { Text("Disconnect") }
          else -> Button(onClick = g::connect) { Text("Connect glasses") }
        }
        if (g.requiresGlassesAppUpdate) {
          OutlinedButton(onClick = { activity?.let(g::openGlassesAppUpdate) }) { Text("Update glasses app") }
        }
      }
    }

    // Head direction
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
      Text("Head direction", style = MaterialTheme.typography.titleMedium)
      Segmented(HeadSource.entries, head.source, { it.label }, model::updateHeadSource)
      when (head.source) {
        HeadSource.MANUAL -> {
          Slider(value = head.manualTurnDeg.toFloat(), onValueChange = { head.manualTurnDeg = it.roundToInt().toDouble() },
              valueRange = -180f..180f)
          val t = head.manualTurnDeg.toInt()
          Caption(if (t == 0) "Looking at the bow" else "Looking ${abs(t)}° to ${if (t < 0) "port" else "starboard"}")
        }
        HeadSource.PHONE ->
          Caption("Hold the phone upright and point it where you're looking. Tap Re-center while pointing at the bow.")
        HeadSource.GLASSES -> {}
      }
      Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        OutlinedButton(onClick = { head.nudge(-2.0) }) { Text("‹ 2°") }
        Button(onClick = head::recenter, modifier = Modifier.weight(1f)) { Text("Re-center on bow") }
        OutlinedButton(onClick = { head.nudge(2.0) }) { Text("2° ›") }
      }
      if (head.fineTuneDeg != 0.0) Caption("Fine tune ${head.fineTuneDeg.toInt()}°")
    }

    if (model.frame.alarmTitle != null) {
      Button(onClick = model::acknowledgeAlarm, modifier = Modifier.fillMaxWidth(),
          colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFD9534F), contentColor = Color.White)) {
        Text("Acknowledge alarm")
      }
    }

    // Link performance, to compare Picture and Text modes on real glasses.
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
      Text("Glasses link", style = MaterialTheme.typography.titleMedium)
      Mono("Lens mode: ${model.lensMode.label}")
      Mono("%.0f ms per update · %.1f updates/s".fmt(g.lastSendMs, g.updatesPerSecond))
      Mono("Motion: ${g.motionStatus} · ${head.samplesPerSecond.toInt()} samples/s")
      Mono("Gestures: ${g.inputsStatus}")
      g.lastSendError?.let { Mono("Last error: $it", Color(0xFFFF7D6E)) }
    }
  }
}

private fun glassesText(m: AppViewModel): String = when (val p = m.glasses.phase) {
  Phase.Idle -> when {
    m.glasses.simulated -> "Simulated glasses ready, not connected"
    m.glasses.isRegistered -> "Registered, not connected"
    else -> "Not registered with Meta AI"
  }
  Phase.Connecting -> "Connecting…"
  Phase.Connected -> "Connected" + if (m.glasses.simulated) " (simulated)" else ""
  is Phase.Failed -> p.reason
}

private fun headText(m: AppViewModel): String {
  val head = m.head
  if (head.source == HeadSource.MANUAL) return "Slider"
  if (head.headTurnDeg == null) return head.status
  val turn = (head.turnFromBow(m.bridge.snapshot?.referenceHeading) ?: 0.0).roundToInt()
  val where = if (turn == 0) "at the bow" else "${abs(turn)}° to ${if (turn < 0) "port" else "starboard"}"
  return "${head.source.label}: looking $where"
}

private enum class Dot(val color: Color) { GOOD(Color(0xFF4CD964)), WAIT(Color(0xFFFF9500)), BAD(Color(0xFFFF3B30)) }

@Composable
private fun StatusRow(title: String, value: String, dot: Dot) {
  Row(verticalAlignment = Alignment.CenterVertically) {
    Box(Modifier.size(10.dp).clip(CircleShape).background(dot.color))
    Spacer(Modifier.width(8.dp))
    Text(title, fontWeight = FontWeight.SemiBold)
    Spacer(Modifier.width(12.dp))
    Text(value, Modifier.weight(1f), color = MaterialTheme.colorScheme.onSurfaceVariant,
        textAlign = androidx.compose.ui.text.style.TextAlign.End)
  }
}

@Composable
private fun Caption(s: String) = Text(s, style = MaterialTheme.typography.bodySmall,
    color = MaterialTheme.colorScheme.onSurfaceVariant)

@Composable
private fun Mono(s: String, color: Color = MaterialTheme.colorScheme.onSurfaceVariant) =
    Text(s, style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace, color = color)

@Composable
private fun <T> Segmented(options: List<T>, selected: T, label: (T) -> String, onSelect: (T) -> Unit) {
  SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
    options.forEachIndexed { i, o ->
      SegmentedButton(selected = o == selected, onClick = { onSelect(o) },
          shape = SegmentedButtonDefaults.itemShape(i, options.size)) { Text(label(o)) }
    }
  }
}

// Settings

@Composable
private fun SettingsScreen(model: AppViewModel, onDone: () -> Unit) {
  var address by remember { mutableStateOf(model.bridgeAddress) }
  val hud = model.hud
  Column(
      Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
      verticalArrangement = Arrangement.spacedBy(24.dp),
  ) {
    Row(verticalAlignment = Alignment.CenterVertically) {
      Text("Settings", style = MaterialTheme.typography.headlineMedium, modifier = Modifier.weight(1f))
      TextButton(onClick = onDone) { Text("Done") }
    }

    Section("Boat data", "The address the TZ Bridge prints when it starts. The phone must be on the boat's Wi-Fi.") {
      SwitchRow("Use demo data", model.useDemoData, model::updateUseDemoData)
      if (!model.useDemoData) {
        OutlinedTextField(value = address, onValueChange = { address = it }, singleLine = true,
            label = { Text("Nav PC address, e.g. 192.168.1.20") },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri), modifier = Modifier.fillMaxWidth())
        Button(onClick = { model.updateBridgeAddress(address) }) { Text("Connect") }
        Caption(model.bridge.status.text)
      }
    }

    Section("Glasses", "Picture sends the HUD as an image (colour, exact positions). Text uses Meta's layout " +
        "components, which send less data and may update faster. Try both on the glasses and compare the update " +
        "rate on the main screen.") {
      Segmented(LensMode.entries, model.lensMode, { it.label }, model::updateLensMode)
      SliderRow("Max updates per second: %.0f".fmt(model.maxUpdatesPerSecond), model.maxUpdatesPerSecond, 1.0..15.0, 1.0,
          model::updateMaxUpdates)
      SwitchRow("Simulated glasses", model.glasses.simulated, model.glasses::useSimulatedGlasses)
    }

    Section("Head tracking", "Turn on Reverse if labels move the wrong way when you turn your head. Adjust Display " +
        "width until a label stays on its ship as you turn: too wide and labels move faster than the ship, too " +
        "narrow and they lag behind.") {
      SwitchRow("Reverse left and right", model.head.reverseDirection, model::updateReverseDirection)
      SliderRow("Display width: %.0f°".fmt(hud.fovDeg), hud.fovDeg, 12.0..40.0, 1.0) { model.updateHud(hud.copy(fovDeg = it)) }
    }

    Section("Targets", "ARPA targets are boats tracked by your radar, including ones without AIS. They show in " +
        "orange; AIS targets in green. Hidden targets don't raise collision alarms.") {
      for ((title, key) in listOf("AIS" to "AIS", "ARPA (radar)" to "ARPA")) {
        SwitchRow(title, key !in hud.hiddenSources) { show ->
          model.updateHud(hud.copy(hiddenSources = if (show) hud.hiddenSources - key else hud.hiddenSources + key))
        }
      }
    }

    Section("Collision alarms", null) {
      SliderRow("Caution under %.2f nm".fmt(hud.cpaCautionNm), hud.cpaCautionNm, 0.1..3.0, 0.05) {
        model.updateHud(hud.copy(cpaCautionNm = it))
      }
      SliderRow("Danger under %.2f nm".fmt(hud.cpaDangerNm), hud.cpaDangerNm, 0.05..2.0, 0.05) {
        model.updateHud(hud.copy(cpaDangerNm = it))
      }
    }

    Section("TimeZero marks", null) {
      SwitchRow("Show marks", hud.showMarks) { model.updateHud(hud.copy(showMarks = it)) }
      SliderRow("Within %.0f nm".fmt(hud.markRangeNm), hud.markRangeNm, 1.0..20.0, 1.0) {
        model.updateHud(hud.copy(markRangeNm = it))
      }
    }
  }
}

@Composable
private fun Section(title: String, footer: String?, content: @Composable () -> Unit) {
  Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
    Text(title.uppercase(), style = MaterialTheme.typography.labelMedium, color = HudGreen)
    content()
    footer?.let { Caption(it) }
  }
}

@Composable
private fun SwitchRow(title: String, on: Boolean, onChange: (Boolean) -> Unit) {
  Row(verticalAlignment = Alignment.CenterVertically) {
    Text(title, Modifier.weight(1f))
    Switch(checked = on, onCheckedChange = onChange)
  }
}

@Composable
private fun SliderRow(title: String, value: Double, range: ClosedFloatingPointRange<Double>, step: Double,
                      onChange: (Double) -> Unit) {
  Column {
    Text(title)
    val steps = ((range.endInclusive - range.start) / step).roundToInt() - 1
    Slider(
        value = value.toFloat(),
        onValueChange = { v -> onChange((Math.round(v / step) * step)) },
        valueRange = range.start.toFloat()..range.endInclusive.toFloat(),
        steps = steps.coerceAtLeast(0),
    )
  }
}
