# TZ Glasses

TimeZero navigation and AIS shown on Meta Ray-Ban Display glasses as labels that stay on the real ships, buoys, marks and waypoints as you turn your head. No camera is involved: positions come from TimeZero, and head direction comes from the glasses' motion sensors.

```
TimeZero (nav PC) ──NMEA (virtual COM) + database──> TZ Glasses Bridge ──WiFi──> phone app ──Bluetooth──> Ray-Ban Display
                                                                              ▲
                                                         glasses motion sensors (head direction)
```

| Folder | What it is | Runs on |
|---|---|---|
| `bridge/` | TZ Glasses Bridge: reads TimeZero's NMEA output and marks database, serves live data to the phone. Windows installer, runs as a service | Windows nav PC |
| `ios/` | iPhone app: head tracking, lens rendering, Meta glasses SDK | iPhone (built on a Mac) |
| `android/` | Android app: the same app in Kotlin | Android phone (built on Windows or Mac) |
| `hud-demo.html` | Browser demo of the lens view | Any browser |

## 1. Bridge (nav PC)

Install it with the Windows installer; no Python needed. Details, options and running from source are in [`bridge/README.md`](bridge/README.md).

1. **Download** `TZ-Glasses-Bridge-Setup-x.y.z.exe` from this repo's **Releases**, or from the latest **Bridge installer** run under **Actions** (Artifacts, at the bottom of the run; needs a GitHub login).
2. **Run it** on the nav PC. Leave **Virtual COM ports** ticked: it installs com0com, which links TimeZero and the bridge on the same PC. Windows SmartScreen may say "Windows protected your PC" because the installer isn't code-signed yet: choose **More info → Run anyway**. The bridge installs as a Windows service that starts with Windows.
3. **Settings** opens at the end (later: Start menu → **TZ Glasses Bridge Settings**). Under **Links to TimeZero on this PC**, press **Bring TimeZero's output to the bridge**. It makes a virtual COM pair and tells you what to set in TimeZero's Connection Wizard: an NMEA 0183 output on one port at 38400 baud, with the sentences to tick. Press **Save**.
4. **AIS receiver on its own COM port?** Add it as a COM input (38400 baud for most AIS) and set **Pass on to → New virtual pair for TimeZero…**. The bridge then shares the receiver with TimeZero, so no splitter program (hub4com, VSPE) is needed. Turn off TimeZero's own input from that port and read the port the page names instead.
5. **Status** (Start menu → **TZ Glasses Bridge**, or http://localhost:8080) shows live data from each input, and at the top, the address to type into the phone app.

TimeZero's marks, routes and tracks are read from its database automatically (read-only).

## 2. iPhone app (on the Mac)

**You need:** Xcode 26.4 or newer, an iPhone on iOS 17.2+, your Apple ID added in Xcode (a free account works, but apps installed with it expire after 7 days), and the Meta AI app on the iPhone.

1. Open `ios/TZGlasses.xcodeproj`. Xcode fetches Meta's SDK (version 1.1.0) on its own the first time.
2. Select the **TZGlasses** target → **Signing & Capabilities** → pick your **Team**. If Xcode says the bundle identifier is taken, change `com.tzglasses.hud` to something unique, such as `com.yourname.tzglasses`.
3. Plug in the iPhone, choose it as the run destination, and press **Run**.

**Try it with no glasses and no boat first.** The app starts with demo data (Halifax Harbour). In Settings, turn on **Simulated glasses**, then on the main screen choose **Phone** as the head direction source. Hold the phone up and turn around: the lens view shows labels moving across, and the cargo ship turns into a collision alarm within about a minute.

## 2b. Android app (on Windows or a Mac)

See `android/README.md`. In short: open the `android/` folder in Android Studio, let it sync, plug in an Android phone (Android 12 or later) with USB debugging on, and press **Run**. It works the same way as the iPhone app: demo data, simulated glasses and the phone or slider head sources all work with no glasses.

## 3. Connect the real glasses

1. In the **Meta AI** app: Settings → your glasses → turn on **Developer Mode**. The glasses need firmware v125 or later and Meta AI v272 or later for display access.
2. In TZ Glasses (iPhone or Android), tap **Register with Meta AI** and approve in Meta AI.
3. Tap **Connect glasses**, then choose **Glasses** as the head direction source.
4. Look at the bow and tap (pinch with the Neural Band) to re-centre.

**Testers' glasses need the app's Meta credentials.** Your own glasses in Developer Mode work without them. For anyone else, register the app in the [Wearables Developer Center](https://wearables.developer.meta.com/) (with the app's bundle ID and your Apple Team ID) to get its **App ID** and **Client Token**. iPhone: copy `ios/Config/MetaSecrets.xcconfig.example` to `ios/Config/MetaSecrets.xcconfig` and fill it in. Android: put them in `android/local.properties` (see `android/README.md`). Both files are kept out of git.

**Motion and Inputs are experimental in Meta's SDK.** They work in Developer Mode, but if the app shows "Motion: Not enabled for this app", enable Motion (and Inputs, for gestures) for your app in the [Wearables Developer Center](https://wearables.developer.meta.com/). Until then, the **Phone** or **Slider** head sources still let you use the lens.

## 4. On the boat

- Phone and nav PC on the same WiFi. In the app's Settings, turn off **Use demo data** and enter the address shown at the top of the bridge's Status page (such as `192.168.1.20:8080`).
- Keep the app open on screen. The phone's auto-lock is turned off while the app is in front. Both iOS and Android may pause network connections for apps in the background, so locking the phone stops updates.

## Gestures on the glasses

| Gesture | Does |
|---|---|
| Tap / pinch the display | Re-centre on the bow, or acknowledge an alarm if one is showing |
| Swipe left / right | Fine-tune 2° (if labels sit slightly off their targets) |
| Swipe up / down | Acknowledge the collision alarm (silenced for 2 minutes) |

## Tuning on first use

- **Labels move the wrong way when you turn:** Settings → Reverse left and right. The app also works this out from the gyroscope after a few head turns.
- **Labels slide off their ship as you turn:** adjust Settings → Display width (default 20°) until a label stays on its target.
- **Labels slowly drift off over minutes:** look at the bow and tap to re-centre. Glasses motion sensors drift; this is expected.
- **Picture vs Text lens mode:** the main screen shows milliseconds per update. Picture is full colour with exact placement; Text sends less data over Bluetooth and may update faster. Use whichever feels smoother when you turn your head.

## Tests

```
python3 ios/tests/test_head_math.py
cd android && ./gradlew test        # same head-tracking cases, plus lens layout and bridge JSON
```
Checks the head-tracking maths (mirrored from `HeadMath.swift`) against simulated head movements, including both quaternion conventions, a reversed gyroscope, tilted heads and re-centring.
