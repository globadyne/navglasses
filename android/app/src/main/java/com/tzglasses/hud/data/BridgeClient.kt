package com.tzglasses.hud.data

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.tzglasses.hud.core.BoatSnapshot
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import kotlin.coroutines.resume

/**
 * Live connection to tz_bridge.py on the nav PC: ws://<pc-address>:8080/ws.
 * Reconnects on its own if the PC, Wi-Fi or bridge drops out. Port of BridgeClient.swift.
 */
class BridgeClient(private val scope: CoroutineScope) {
  sealed class Status(val text: String) {
    data object Off : Status("Off")
    data object Connecting : Status("Connecting…")
    data object Live : Status("Live")
    data object NoData : Status("Connected, TimeZero not sending")
    class Failed(reason: String) : Status(reason)
  }

  var snapshot by mutableStateOf<BoatSnapshot?>(null); private set
  var status by mutableStateOf<Status>(Status.Off); private set
  var lastMessageAt by mutableStateOf(0L); private set

  private var address = ""
  private var loop: Job? = null
  private var socket: WebSocket? = null
  private val http = OkHttpClient.Builder()
      .connectTimeout(10, TimeUnit.SECONDS)
      .readTimeout(15, TimeUnit.SECONDS)  // the bridge sends several times a second
      .build()

  fun connect(to: String) {
    disconnect()
    address = to
    val url = url(to)
    if (url == null) {
      status = Status.Failed("Enter the nav PC's address in Settings")
      return
    }
    loop = scope.launch {
      while (true) {
        runOnce(url)
        delay(2000)
      }
    }
  }

  fun disconnect() {
    loop?.cancel()
    loop = null
    socket?.close(1001, null)
    socket = null
    status = Status.Off
  }

  /** Used by the demo feed so the rest of the app works without a bridge. */
  fun inject(snap: BoatSnapshot) {
    snapshot = snap
    lastMessageAt = System.currentTimeMillis()
  }

  /** Runs one connection until it closes or fails. Messages are applied on the main thread. */
  private suspend fun runOnce(url: String) {
    status = Status.Connecting
    suspendCancellableCoroutine { cont ->
      val ws = http.newWebSocket(Request.Builder().url(url).build(), object : WebSocketListener() {
        override fun onMessage(webSocket: WebSocket, text: String) {
          val snap = runCatching { BoatSnapshot.parse(text) }.getOrNull()
          scope.launch(Dispatchers.Main) {
            if (snap == null) {
              status = Status.Failed("Unexpected data from the bridge")
            } else {
              snapshot = snap
              lastMessageAt = System.currentTimeMillis()
              status = if ((snap.rxAgeS ?: 99.0) < 5) Status.Live else Status.NoData
            }
          }
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
          if (cont.isActive) cont.resume(Unit)
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
          scope.launch(Dispatchers.Main) { status = Status.Failed("Can't reach the bridge at $address. Retrying…") }
          if (cont.isActive) cont.resume(Unit)
        }
      })
      socket = ws
      cont.invokeOnCancellation { ws.cancel() }
    }
  }

  companion object {
    /** Accepts "192.168.1.20", "192.168.1.20:8080" or "ws://…/ws". */
    fun url(address: String): String? {
      var a = address.trim()
      if (a.isEmpty()) return null
      if (a.startsWith("ws://") || a.startsWith("wss://")) return a
      a = a.removePrefix("http://")
      val host = a.substringBefore('/')
      return "ws://$host${if (':' in host) "" else ":8080"}/ws"
    }
  }
}
