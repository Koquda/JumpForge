# Inspect the first implementation

The repository contains a native Swift app with a Mac companion and an iPhone target. It implements the record or import, review, save, and compare workflow. The iPhone simulator target compiled successfully in GitHub's Xcode environment. Physical iPhone capture has not been exercised.

## Inspect the completed functionality

- Create athletes and CMJ or squat-jump sessions.
- Import local video with actual source sample timestamps.
- Navigate by exact frame number, frame steps, or a slider. Zoom and pan the preview to inspect the feet.
- Confirm original timing for imported footage. Known retiming blocks measurement.
- Request experimental pose-based suggestions. Suggestions locate review regions and never confirm contact events.
- Mark and review takeoff and landing. See flight-time height and the sampling interval range.
- Save attempts and append analysis revisions without discarding earlier measurements.
- View session statistics and protocol-specific progress charts.
- Export revision-aware CSV.
- Export a portable backup with original media, metadata, and integrity checksums. Restore merges without replacing conflicting records.

## Reproduce the checks

Run `sh Scripts/check.sh`. The script uses a temporary build directory to avoid File Provider metadata on generated signed bundles. It detects a command-line-tool Testing macro plugin when required. No third-party toolchain or prohibited-language script is needed.

The initial verification passed 25 automated tests. Twelve cover core calculations, timestamps, state validation, CSV, and storage recovery. Eight cover portable backups, corruption, conflicts, symlinks, and restoration. Five cover generated 120 fps video, exact decoded frames, rotation, corrupt video, and pose-signal behavior.

The automated video checks require access to the operating system's video encoder. An environment that blocks that service produces an encoding failure, not a valid test result. Run them in a normal local development environment.

For a synthetic review clip, compile and run the Swift fixture generator.

```sh
swiftc -parse-as-library Scripts/GenerateFixture.swift -o /private/tmp/jumpforge-generate-fixture
/private/tmp/jumpforge-generate-fixture /private/tmp/JumpForge-fixture.mov
```

Choose a new output path. The clip has 240 samples at 120 fps. The first airborne sample is index 60 and the first landing sample is index 120. The interface labels these as frames 61 and 121. The expected midpoint flight time is 0.500 seconds and the height estimate is 30.64578125 cm using standard gravity 9.80665 m/s². This is an artificial timing fixture, not real-athlete accuracy evidence.

The live Mac check used an isolated library through `JUMPFORGE_DATA_DIR`. It created an athlete, imported the synthetic clip, navigated to both event samples, confirmed timing, saved a 30.6 cm estimate, viewed progress, exported CSV, exported a full backup, and restored the identical backup without duplication. Saving stayed disabled before timing confirmation.

## Track the open release gates

The Mac app has compiled and run. The iPhone simulator target also compiled in [GitHub's successful Xcode run](https://github.com/Koquda/JumpForge/actions/runs/40521357968) at code revision 3343af9. Physical camera permissions, high-speed capture, distribution signing, accessibility checks on devices, thermal measurements, performance budgets, the paired My Jump comparison, and force-plate validation remain open.

The automatic detector uses a coarse ankle-rise signal and can abstain. It cannot establish foot contact from pose landmarks alone. Do not describe it as validated automatic jump measurement.

The first app uses versioned atomic JSON and separate video files. This replaces the plan's proposed SwiftData storage so record validation and recovery can be exercised through the command-line Swift tests. A single desktop window avoids multiple unsynchronized UI copies of the same library. Cloud synchronization and concurrent editing across app processes are outside this release.

## Read the design decisions

Model the Domain produced explicit timing provenance, rational sample stamps, and preserved revisions. Sequence work into verifiable units put timing and manual review ahead of suggestions. Prove It Works required actual decoding and live native-app checks. Type System Discipline kept video timestamps and analysis records in named value types. Suggestions remain proposals until a person reviews the events.

The live check also reopened an attempt, reviewed both saved events, appended a second analysis revision, and confirmed that session statistics still count one attempt. Switching to the squat-jump protocol showed no CMJ results. These checks used synthetic footage and an isolated local test library.
