# Verify JumpForge before release

Run checks at an exact source revision and save the device model, OS, compiler, fixtures, commands, and outputs with each result.

## Check calculations and persistence

- [ ] Run `swift test`.
- [ ] Verify the flight-time formula against hand-calculated fixtures.
- [ ] Verify rational timestamps, variable-rate samples, invalid ordering, event bounds, and retiming rejection.
- [ ] Save a session, restart the app offline, and confirm that its measurements and selected samples survive.
- [ ] Corrupt a copied test library and exercise previous-snapshot recovery. Never corrupt a real athlete library.
- [ ] Inspect CSV units, protocol identifiers, timing provenance, and spreadsheet-formula neutralization.

## Check the actual interface

- [ ] Create an athlete and a session on macOS.
- [ ] Import a known original clip and confirm actual displayed source samples.
- [ ] Keep measurement saving disabled until timing and event review are explicit.
- [ ] Save several jumps into one session and reopen a saved jump for correction.
- [ ] Confirm that previous analysis revisions remain available after correction.
- [ ] Compare CMJ and squat-jump histories separately.
- [ ] Exercise VoiceOver, larger text, keyboard access, and reduced motion.
- [ ] Export and restore a portable backup with media in a separate test library.

## Check iPhone capture

- [ ] Compile the iOS simulator target with full Xcode.
- [ ] Run the app on the lowest supported physical phone and a newer phone.
- [ ] Exercise granted and denied camera permission.
- [ ] Verify supported 120 or 240 fps configuration through actual recorded samples.
- [ ] Check portrait and landscape video, low light, capture cancellation, background interruption, and full storage.
- [ ] Confirm that no microphone or network access is required.

## Measure performance

All budgets below are proposed. They are not measured speed claims.

- [ ] Record cold-launch p95 on the minimum supported phone. Target below 2 seconds.
- [ ] Record exact-frame review latency after indexing. Target p95 below 100 ms.
- [ ] Record end-to-end suggestion latency for a 10-second local clip. Target p95 below 3 seconds.
- [ ] Run 20 clips consecutively. Inspect memory, energy, thermal state, and latency growth.
- [ ] Compare the same workload against main in alternating order. Do not calculate a speedup where main lacks the feature.

## Validate measurements and comparisons

- [ ] Freeze capture setup, event definitions, force-plate thresholds, and exclusion rules before testing.
- [ ] Collect simultaneous phone and force-plate recordings with consent.
- [ ] Compare flight-time estimates against force-plate flight time. Separately report disagreement with takeoff-velocity height.
- [ ] Use athlete-level held-out footage for detection evaluation. Report abstention and failure rates with event errors.
- [ ] Obtain independent expert frame annotations and adjudicate disagreements.
- [ ] Report bias, absolute error, limits of agreement, repeatability, and athlete-clustered uncertainty.
- [ ] Test CMJ and squat jumps independently. Do not generalize validation to drop jumps.
- [ ] Compare the same five-jump workflow against the current My Jump version with counterbalanced users and equal practice.
- [ ] Claim better speed or accuracy only when the predeclared comparison passes.

## Track known limitations

The first implementation uses manual review as the confirmation gate. Pose-derived suggestions require local visual checks and independent validation. They do not establish actual foot contact. Imported video timing can be ambiguous even if its sample spacing is regular. Frame sampling bounds do not account for posture changes or all measurement errors.

The initial development environment has Swift command-line tools but no full Xcode installation. Native Mac execution is locally verifiable. iOS SDK compilation, physical capture, signing, TestFlight distribution, and force-plate validation require separate evidence.
