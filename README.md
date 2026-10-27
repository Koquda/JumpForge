# JumpForge

Native Swift jump review for athletes and coaches. Import a video, inspect actual source samples, mark takeoff and landing, and keep protocol-specific results offline. The app estimates jump height from flight time. It does not measure ground reaction force.

## Run on a Mac

Requires macOS 14 or later and a Swift 6 toolchain.

```sh
swift build
sh Scripts/check.sh
sh Scripts/bundle-macos.sh
open .build/JumpForge.app
```

The macOS companion uses the same measurement core, video adapter, and interface as the iPhone app. No Node runtime, JavaScript, TypeScript, Python, or third-party package is required. The CI workflow uses shell commands and Swift, without JavaScript-based checkout actions.

## Run on an iPhone

Open `iOS/JumpForge.xcodeproj` in full Xcode. Select the JumpForge scheme, choose your signing team and a connected device, then run. The project targets iOS 17 or later. Camera recording needs a physical iPhone. The app requests camera access when you record. It does not need microphone access.

```sh
xcodebuild -project iOS/JumpForge.xcodeproj -scheme JumpForge \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

## Review a jump

1. Create an athlete and select the jump protocol.
2. Import original video or record on iPhone. Keep the athlete and their feet visible with the camera stationary.
3. Inspect the timing information. Imported footage needs an explicit original real-time confirmation. Retimed footage cannot produce a confirmed measurement.
4. Find the first sample where both feet have left the ground. Mark and review takeoff.
5. Find the first sample where a foot touches the ground. Mark and review landing.
6. Inspect the estimated height, flight time, and sampling uncertainty. Confirm the frames and save.
7. Compare only equivalent protocols. Export results as CSV when needed.

Automatic event suggestions are experimental. Inspect both events before confirming. Missing feet, multiple people, unsuitable timing, or poor motion evidence can cause abstention. A suggestion is not a validated result.

## Understand timing

`JumpCore` stores integer sample timestamps and their timescales. It derives event intervals from the previous and selected sample. It computes flight-time bounds and height bounds from those intervals. It does not calculate elapsed time as frame count divided by nominal playback frame rate.

Height is `9.80665 × flight time² ÷ 8`. This estimates takeoff-to-apex centre-of-mass rise under the equal takeoff and landing posture assumption. Sampling bounds do not include posture error, camera blur, or detector error. A result with more decimal places is not necessarily more accurate.

Slow-motion exports can discard the information needed to recover physical recording time. Metadata can detect some edits but cannot prove that arbitrary imported footage preserves real time. Confirm original timing only when you know the file's provenance. Never confirm slowed screen recordings or edited social videos.

## Keep data local

The app stores metadata and copied media in its application support directory. Metadata writes are atomic and keep a previous valid snapshot for recovery. Videos remain outside the repository. There are no accounts, analytics endpoints, subscriptions, or remote processing in this implementation.

## Inspect the source

- `Sources/JumpCore` owns validated measurement values, revisions, history summaries, CSV, and local records.
- `Sources/JumpMedia` owns AVFoundation indexing, exact sample images, pose-based suggestions, and iPhone capture.
- `Sources/JumpUI` owns native screens and review state.
- `Sources/JumpForgeDesktop` launches the Mac companion.
- `iOS` contains the iPhone app target and permission declarations.
- `Documentation/Validation.md` defines the outstanding device and measurement checks.

The implementation has not established superiority over My Jump. Force-plate validation and a paired usability comparison are release gates.

## Back up or restore

Open the drive button in the header. Export full backup creates a `.jumpforgebackup` package with metadata, original media, and checksums. Restore adds records, accepts an identical repeated backup, and rejects conflicting records instead of overwriting them. The package limits are 10,000 files, less than 50 MB per metadata file, and less than 4 GB total. Keep the package intact.

See `Documentation/Implementation.md` for the verified behavior, synthetic fixture recipe, and outstanding release checks.
