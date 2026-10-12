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
