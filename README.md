# TZ Glasses

TimeZero navigation and AIS shown on Meta Ray-Ban Display glasses as labels that stay on the real ships, buoys, marks and waypoints as you turn your head. No camera is involved: positions come from TimeZero, and head direction comes from the glasses' motion sensors.

```
TimeZero (nav PC) ──UDP NMEA + database──> bridge/tz_bridge.py ──WiFi──> iPhone app ──Bluetooth──> Ray-Ban Display
                                                                              ▲
                                                         glasses motion sensors (head direction)
```

| Folder | What it is | Runs on |
|---|---|---|
| `bridge/` | Reads TimeZero's NMEA output and marks database, serves live JSON | Windows nav PC |
| `ios/` | iPhone app: head tracking, lens rendering, Meta glasses SDK | iPhone (built on a Mac) |
| `hud-demo.html` | Browser demo of the lens view | Any browser |

## 1. Bridge (nav PC)

See `bridge/README.md`. In short:

```
pip install -r bridge/requirements.txt
python bridge/tz_bridge.py --udp 10110 --tzdb "C:\ProgramData\TimeZero\DATA\UserObjects.tzdb"
```

TimeZero sends NMEA by UDP to `127.0.0.1:10110` (Connection Wizard → UDP). Open http://localhost:8080 to check data is arriving.

## 2. iPhone app (on the Mac)

**You need:** Xcode 26.4 or newer, an iPhone on iOS 17.2+, your Apple ID added in Xcode (a free account works, but apps installed with it expire after 7 days), and the Meta AI app on the iPhone.

1. Open `ios/TZGlasses.xcodeproj`. Xcode fetches Meta's SDK (version 1.1.0) on its own the first time.
2. Select the **TZGlasses** target → **Signing & Capabilities** → pick your **Team**. If Xcode says the bundle identifier is taken, change `com.tzglasses.hud` to something unique, such as `com.yourname.tzglasses`.
3. Plug in the iPhone, choose it as the run destination, and press **Run**.

**Try it with no glasses and no boat first.** The app starts with demo data (Halifax Harbour). In Settings, turn on **Simulated glasses**, then on the main screen choose **Phone** as the head direction source. Hold the phone up and turn around: the lens view shows labels moving across, and the cargo ship turns into a collision alarm within about a minute.

## 3. Connect the real glasses

1. In the **Meta AI** app: Settings → your glasses → turn on **Developer Mode**. The glasses need firmware v125 or later and Meta AI v272 or later for display access.
2. In TZ Glasses, tap **Register with Meta AI** and approve in Meta AI.
3. Tap **Connect glasses**, then choose **Glasses** as the head direction source.
4. Look at the bow and tap (pinch with the Neural Band) to re-centre.

**Motion and Inputs are experimental in Meta's SDK.** They work in Developer Mode, but if the app shows "Motion: Not enabled for this app", enable Motion (and Inputs, for gestures) for your app in the [Wearables Developer Center](https://wearables.developer.meta.com/). Until then, the **Phone** or **Slider** head sources still let you use the lens.

## 4. On the boat

- Phone and nav PC on the same WiFi. In Settings, turn off **Use demo data** and enter the nav PC's address (the bridge prints it at start-up, such as `192.168.1.20`).
- Keep the app open on screen. The phone's auto-lock is turned off while the app is in front. iOS pauses network connections for apps in the background, so locking the phone stops updates.

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
```
Checks the head-tracking maths (mirrored from `HeadMath.swift`) against simulated head movements, including both quaternion conventions, a reversed gyroscope, tilted heads and re-centring.
