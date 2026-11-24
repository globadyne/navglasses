# TZ Glasses for Android

The same app as `ios/`, in Kotlin with Jetpack Compose, built on Meta's Wearables Device Access Toolkit for Android 1.1.0. It follows Meta's DisplayAccess and BirdSpotter samples.

## Build and run

**You need:** Android Studio (a recent stable version), an Android phone on Android 12 (API 31) or later with USB debugging turned on, and the Meta AI app on the phone.

1. Open the `android/` folder in Android Studio. It downloads Gradle, the Android SDK 36 and Meta's SDK from Maven Central on its own. No GitHub token is needed.
2. Plug in the phone, choose it as the run target, and press **Run**.
3. Allow Bluetooth when asked.

From a terminal: `./gradlew installDebug` (Windows: `gradlew.bat installDebug`).

**Try it with no glasses first.** It starts with demo data (Halifax Harbour). In Settings, turn on **Simulated glasses**, go back, and tap **Connect glasses**. The simulated glasses' own screen appears under the lens view. Choose **Phone** as the head direction source and point the phone around.

### Meta app credentials

Developer Mode on the glasses needs no credentials. To ship to testers, register the app in the [Wearables Developer Center](https://wearables.developer.meta.com/) and put the values in `android/local.properties` (it isn't committed):

```
mwdat_application_id=YOUR_APP_ID
mwdat_client_token=YOUR_CLIENT_TOKEN
```

Motion (head tracking) and Inputs (gestures) are experimental capabilities; enable them for the app there too.

## Layout

| File | What it does | Mirrors (iOS) |
|---|---|---|
| `core/BoatData.kt`, `core/Json.kt` | The bridge's JSON (`/ws`, `/state.json`) | `BoatData.swift` |
| `core/HudModel.kt` | Decides what the lens shows (labels, alarms, edge cues) | `HUDModel.swift` |
| `core/HeadMath.kt` | Head yaw from the glasses' quaternion, convention and sign detected at runtime | `HeadMath.swift` |
| `core/DemoFeed.kt` | Built-in sample traffic | `DemoFeed.swift` |
| `head/HeadTracker.kt` | Gaze bearing from glasses, phone sensors or slider | `HeadTracker.swift` |
| `data/BridgeClient.kt` | WebSocket to the bridge, reconnects on its own (OkHttp) | `BridgeClient.swift` |
| `render/HudBitmapRenderer.kt` | Draws the 600 × 600 lens picture | `HUDImageRenderer.swift` |
| `glasses/HudDisplayLayout.kt` | Picture and Text lens modes in Meta's display components | `HUDDisplayLayout.swift` |
| `glasses/GlassesController.kt` | Registration, session, Display, Motion, Inputs, simulated glasses | `GlassesController.swift` |
| `AppViewModel.kt` | The 20 Hz loop and saved settings | `AppModel.swift` |
| `ui/Screens.kt` | Main and Settings screens | `ContentView.swift`, `SettingsView.swift` |

Everything in `core/` is plain Kotlin with no Android imports, so it runs in unit tests on any JVM.

## Tests

```
./gradlew test
```

`app/src/test/.../CoreChecks.kt` runs the same simulated head movements as `ios/tests/test_head_math.py` (both quaternion conventions, reversed gyroscope, tilted heads, re-centring), plus lens placement, source hiding, alarms, the bridge's JSON and the demo scenario, over ten random seeds.

Without Gradle, the core can be checked with just the Kotlin compiler:

```
kotlinc app/src/main/java/com/tzglasses/hud/core/*.kt app/src/test/java/com/tzglasses/hud/core/CoreChecks.kt -include-runtime -d checks.jar
java -cp checks.jar com.tzglasses.hud.core.CoreChecksKt
```

## Status

The `core/` code compiles and passes its checks. The Android and Meta SDK parts were written against Meta's 1.1.0 samples but **have not been through a Gradle build yet** (the environment they were written in couldn't reach Google's Maven repository). The first job on a machine with Android Studio is to sync, build, and fix any small compile errors.
