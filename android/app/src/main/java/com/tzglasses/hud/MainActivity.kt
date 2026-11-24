package com.tzglasses.hud

import android.Manifest.permission.BLUETOOTH
import android.Manifest.permission.BLUETOOTH_CONNECT
import android.Manifest.permission.INTERNET
import android.os.Bundle
import android.view.WindowManager
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts.RequestMultiplePermissions
import androidx.activity.viewModels
import com.meta.wearable.dat.core.Wearables
import com.tzglasses.hud.ui.TZGlassesApp

class MainActivity : ComponentActivity() {
  private val model: AppViewModel by viewModels()

  private val permissions = registerForActivityResult(RequestMultiplePermissions()) { results ->
    if (results.values.all { it }) {
      Wearables.initialize(this)
      model.start()
    } else {
      Toast.makeText(this, "Bluetooth permission is needed to reach the glasses", Toast.LENGTH_LONG).show()
    }
  }

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    enableEdgeToEdge()
    // The phone stays in a pocket or on a mount at the helm; keep it awake while the app is open.
    window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    setContent { TZGlassesApp(model) }
  }

  override fun onStart() {
    super.onStart()
    permissions.launch(arrayOf(BLUETOOTH, BLUETOOTH_CONNECT, INTERNET))
  }
}
