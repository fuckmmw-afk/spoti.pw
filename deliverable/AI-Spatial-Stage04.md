# Stage 04 — build milestones and acceptance

Current release: **A — Timing & Spatial Core**. Builds B–G are work in progress.
Spatial Live is compile-gated until build E, and new croma UI/migration until F.
A keeps the Stage 03 UI and JamesDSP/Separator audio behavior.

A fixes mixed wall/monotonic clocks, reports queue wait separately, measures
processing average once per analysis block, uses the event START deadline,
and checks the live PCM input/output cursors. It rejects late, duplicate and
old-epoch events. The classifier remains the Stage 03 classifier.

The old ten-event limit was per stem and used a fixed time bucket. A now has
a shared rolling 60-second monotonic budget (maximum ten over both stems),
retained across track/route/seek epochs. Sample-domain spacing is 350 ms.
The provided local debug ZIP has no Accent Trace; the user's exact 20/12s
segment is not independently verified. Synthetic replay covers that case.

The independent C scene stores position, distance, source size and gain.
Six motion types return smoothly to the base position with bounded gesture
length and smooth attack/release. No Core ML model or IPA is included.

Run `make -C ai_spatial test`. A covers source-indexed deadlines at 44.1/48kHz,
rolling density, duplicate/epoch cancellation, timing validity and scene/motion
continuity. This is not an iPhone listening or 60-minute stability result.

Install A's `aispatial.dylib` and matching plist in place of Stage 03; keep
existing croma and JamesDSP files. Downloaded model stays in the app container.
Start Original, then AI Shadow with Accent Detector on. Export Accent events
and Detailed diagnostics after >=2 minutes, including pause/resume, seek,
track and route changes. Verify selected events have `timely=true`, positive
start-deadline slack, no huge negative clock values, <=10 selections in any
60-second monotonic window, and no old-epoch selections after a boundary.

Next milestones: B event extraction; C actual HRTF with headphone listening;
D stereo/mono renderers and route profiles; E live pipeline; F unified UI and
config migration; G tuning, performance measurements and physical 60-minute
acceptance. Their current source scaffolding is not claimed as completed.
