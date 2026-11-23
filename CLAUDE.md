# TZ Glasses: notes for Claude Code

Head-tracked AR navigation labels for Meta Ray-Ban Display glasses, fed by TimeZero Professional. Read README.md first for the overall setup.

## Status (handed over from a Claude chat session, 2026-11-23)

- `bridge/`: Python, tested end to end (UDP, serial, TimeZero database, GPX, WebSocket). Runs on the user's Windows 11 nav PC next to TimeZero Professional **v4**.
- `ios/`: written against the **real** Meta DAT SDK 1.1.0 interface files (`.swiftinterface` in the xcframeworks), following Meta's DisplayAccess sample. **It has not been compiled yet**: no Swift toolchain was available where it was written. The first job is to build it and fix any compile errors.
- `ios/tests/test_head_math.py`: Python mirror of `HeadMath.swift`; passes. Keep the two in step if you change either.

## First tasks

1. `cd ios && xcodebuild -scheme TZGlasses -destination 'generic/platform=iOS Simulator' build` and fix errors. Expect small ones (result-builder edge cases in `HUDDisplayLayout.swift`, `@Observable` + `didSet`, Swift 5 vs 6 concurrency). The target is set to `SWIFT_VERSION = 5.0` with minimal concurrency checking on purpose; Meta's sample uses 6.0.
2. Run in the simulator: demo data plus Settings → Simulated glasses should show the lens preview and the simulated glasses' own preview.
3. Then on the user's iPhone with signing (their team). The bundle ID `com.tzglasses.hud` may need changing.

Regenerate the Xcode project after adding or removing Swift files: `python3 ios/make_xcodeproj.py`. Or convert to Xcode's synchronized folders if you prefer.

## Meta SDK facts (verified from 1.1.0 interface files, not guessed)

- SPM: `https://github.com/meta/meta-wearables-dat-ios`, exact 1.1.0. Products: MWDATCore, MWDATDisplay, MWDATMotion, MWDATInputs, MWDATMockDevice.
- Install Meta's Claude Code plugin for live docs: `curl -sL https://raw.githubusercontent.com/facebook/meta-wearables-dat-ios/main/install-skills.sh | bash`, or connect the MCP server `https://mcp.developer.meta.com/wearables`.
- Display content is a single root `FlexBox` per `send()` (Text, Button, ButtonGroup, Image, Icon, VideoPlayer). There's no free drawing or absolute positioning, and text colour is only `.primary` / `.secondary`. That's why there are two lens modes:
  - `.picture`: the HUD drawn into a 600×600 `UIImage`, sent as `Image(image:)`. Full control; bigger transfer.
  - `.text`: FlexBox rows with flexible spacers to slide labels sideways.
  Which is better on real glasses is an open question: compare `lastSendMs` on device.
- Motion (`session.addMotion`) and Inputs (`session.addInputs`) are **experimental**. They must be enabled for the app in the Wearables Developer Center for production; Developer Mode may allow them. `MotionSample.orientation` is a quaternion with an **undocumented reference frame**. `HeadMath` detects the convention and sign at runtime, so don't hard-code an axis.
- Display and Motion need the `DeviceSession` in `.started` first; wait for `DisplayState.started` before sending.

## Data flow

`BridgeClient` (WebSocket JSON, see `BoatData.swift`) or `DemoFeed` → `AppModel.tick()` at 20 Hz → `HeadTracker.gaze()` → `HUDBuilder.build()` → `HUDImageRenderer` (phone preview and picture mode) → `GlassesController.send()`. Sends happen only when the frame changes or every 2 s, never overlapping, and capped by the "max updates per second" setting.

Gaze = boat heading at calibration + head turn since calibration + fine-tune. Using the heading at calibration (not live) is intentional: the glasses measure against the world, so labels stay put when the boat turns under a still head.

## Bridge facts

- TimeZero 4 output has no raw AIS (VDM). AIS arrives as **TTM** (target number, range, bearing, speed, course, CPA, TCPA, name), so there's no vessel type. TZ5 can export AIS, or the AIS receiver can be fed to the bridge directly.
- Marks and routes are read live, read-only, from `C:\ProgramData\TimeZero\DATA\UserObjects.tzdb` (SQLite). Geometry: 1 type byte, then big-endian int32 (lon, lat) pairs scaled 2^31 = 180°. Object type 0 = mark, 5 = route. Dates are seconds since 2000-01-01. Decoded positions matched the user's marks off Nova Scotia's Eastern Shore. Tracks live in `Tracks2.tzdb` (not decoded yet; it was empty).
- TimeZero runs as administrator on the nav PC, so computer-use input into TimeZero is blocked; use the user's screenshots instead.

## Ideas not built yet

- Predict head yaw ahead by the measured display latency (gyro rate × latency) so labels don't trail on fast turns.
- Bonjour discovery of the bridge, so there's no IP to type.
- Decode `Tracks2.tzdb` and draw recent tracks.
- Run the bridge as a Windows service.
