# Stage 04 — Builds B–F

Build A remains the timing foundation: monotonic deadlines, rolling event
density, epoch invalidation, duplicate rejection and the independent scene
core. Builds B–F now add the live spatial path.

Build B contains `AISpatialEventExtraction`: selected events use bounded
raised-cosine attack/release envelopes, a short tail, deterministic overlap
arbitration and source-indexed foreground deltas. The motion core supports
Flyby, Arc, Depth, Bloom, Subtle Shift and Spatial Reflection with smooth
interpolation, optional authored endpoints and bounded gesture duration.

Build C provides a static headphone binaural renderer with equal-power ILD,
bounded crossfeed and reflection cues. HRTF processing is optional and does
not require head-tracking permission. `AISpatialHeadTracking` is an optional
adapter for compatible AirPods; when unavailable the scene remains static.

Build D selects Headphones, Speakers, Universal Stereo or Mono/Safe. Bluetooth
A2DP is treated as an unknown stereo route unless the system-reported name is a
known headphone family. Profiles are persisted by the existing settings page;
unknown routes use conservative width and no aggressive anti-phase processing.

Build E connects the existing Separator and Accent Detector to the render-side
bounded ring, applies spatial deltas before the single JamesDSP invocation, and
falls back to same-index original PCM on underrun, model failure or unsupported
sample rate. Original and Shadow preserve the current audible path.

Build F extends the AI Spatial page with mode, route/profile, intensity, width,
depth, density, motion component switches, reflections, vocal/bass protection,
HRTF and trace/export controls. Exports include both legacy names and
`spatial-diagnostics.log`, `spatial-events.jsonl`, `spatial-summary.json`, and
`spatial-timeline.csv`.

## Verification

`make -C ai_spatial test` runs host tests for the ring, resampler, extraction
envelopes, overlap arbitration, scene trajectories, renderer limits, timing,
epoch cancellation, mono safety, and bounded queues. The standalone tweak and
JamesDSP bridge build with Theos at phase 6 in CI. These checks do not prove
subjective sound quality, thermal headroom, or 60-minute stability on an
iPhone; those require the user's iPhone 16 Pro and output devices.

Install the staged `aispatial.dylib` and plist plus the matching
`chromajdsp.dylib` and plist through the existing tweak mechanism. Keep the
downloaded model in Spotify's app container. Start in **Original**, then
**Spatial Shadow** to verify events and trace without changing sound, and only
then enable **Spatial Live**. Export diagnostics from AI Spatial → Diagnostics
or the settings page. Do not send exports or PCM off-device automatically.

## Stage 04 incident diagnosis

The supplied debug archive showed that the first five-second clip was taken
before the user switched from Shadow/Original to Live. The selected events in
epochs 9 and 11 were therefore invalidated at the Live boundary; the value
`spatial_events_applied=7680` was one event's processed sample count, not 7680
events. The old export also wrote `Difference.wav` and
`Event-Foreground.wav` as raw float32 payloads and did not prove the terminal
JamesDSP buffer.

The fix keeps one audible owner for the path (Spotify callback → Spatial →
JamesDSP → terminal AudioBufferList), captures the terminal buffer after
JamesDSP, clears stale pending events at epoch boundaries, separates cumulative
event lifecycle counters from per-second frame counters, and writes four
aligned float32 WAVs with a sidecar containing exact sample bounds and metrics.

## Stage 04 output-path self-test

The Diagnostics page now exposes **Run Spatial Output Self-Test (A → B → C)**.
It bypasses Accent Detector for one finite run and restores the previous mode:

- **A Output Path Test** changes the same in-place PCM buffer that JamesDSP
  receives. Its terminal buffer is captured after JamesDSP.
- **B Renderer Test** runs one-second trajectories through Headphones, Speakers,
  Universal Stereo and Mono/Safe.
- **C Event Integration Test** schedules future sample-indexed events through
  the normal scheduler, mixer and output callback without Core ML input.

Use a safe listening level. A report with `terminal_output_verified=false`
cannot prove audible output and must not be treated as a Spatial Live fix.
`spatial-clips/spatial-export.json` gives the exact sample range, WAV metrics,
changed-sample percentage, renderer/profile identity and event counters.
