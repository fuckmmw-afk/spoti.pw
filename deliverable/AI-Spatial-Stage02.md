# AI Spatial — Stage 02

Stage 02 adds a bounded streaming path around the Stage 01 separator:

```text
Spotify PCM
  -> Croma/JDSP post-render bridge (pre-JamesDSP)
  -> bounded SPSC input ring (epoch + sample index)
  -> serial worker, 2.0 s window / 1.5 s step / 0.5 s overlap
  -> Stage 01 STFT + downloaded Mel-Band RoFormer Core ML + ISTFT
  -> synchronized vocal/instrumental frames
  -> bounded output ring and same-index mixer
  -> JamesDSP exactly once
  -> Spotify output
```

The audio callback copies bounded PCM, updates atomic cursors, performs only bounded scalar capture metrics and reads completed frames. Core ML, resampling, overlap reconstruction, detailed diagnostics and file I/O run off the callback. The worker is serial, so there is at most one in-flight prediction. Every input, output and window carries an epoch and absolute sample range; a seek, track change, route change, interruption or media-service reset invalidates the old epoch. If the companion bridge is missing or cannot attach its import hook, the existing post-render observer feeds the common float32 non-interleaved stereo route into the same AI entry point; callback timestamp/frame deduplication prevents double processing when both hooks are present.

Modes are `Original`, `AI Shadow`, `AI Live`, and the explicitly marked test modes `Vocals Only (test)` and `Instrumental Only (test)`. AI Live uses the configured 2.75 s source-index delay. Before a stem frame is ready, the render side uses the original sample from that same delayed index; it never combines current original PCM with a processed frame from another position. A 20 ms gain ramp avoids hard mode and fallback edges. In Shadow, the model runs and diagnostics are collected while the original output remains audible.

## Build

The model is not in the repository or artifact. The user downloads and verifies it from Hugging Face through the existing Stage 01 UI.

```sh
PATH=/tmp/chroma-tools:$PATH THEOS=/root/theos make -C ai_spatial test
PATH=/tmp/chroma-tools:$PATH THEOS=/root/theos make -C ai_spatial clean stage
PATH=/tmp/chroma-tools:$PATH THEOS=/root/theos make -C bridge
```

GitHub Actions runs the host stream-core tests, refuses model/IPA files, builds `aispatial.dylib`, and publishes only the tweak, plist and README. It does not claim device execution.

## iPhone verification

1. Install the staged `aispatial.dylib` alongside the existing JamesDSP/Croma tweak. Keep the existing JamesDSP files and presets.
2. In Spotify → AI Spatial, download and verify the model. Start **Detailed** diagnostics (use **Full Trace** only for a bounded debug capture).
3. Select **Original**, then **AI Shadow**. Confirm the original sound continues and the status shows growing window/inference counters.
4. Select **AI Live**. Export diagnostics after at least five minutes. Check `additional_latency_seconds`, `inference_p95_ms`, queue depths, stem drift, reconstruction error, underruns, overflows and fallback transitions.
5. Repeat with pause/resume, seek, track changes, Spotify restart, screen lock, background playback, Bluetooth disconnect/reconnect, speaker output and a route-rate change. For the endurance run, collect 30–60 minutes and at least 20 track changes.
6. Export the report from the Diagnostics page. The report contains JSON-line stage events, one CSV row per second and metadata. Full Trace retains only bounded PCM/tensor windows when explicitly enabled.

The Diagnostics page now shows `streaming_callback_blocks`, `streaming_callback_frames` and duplicate callback blocks. A zero callback count with only `spotify_realtime_capture` rows means the render bridge did not reach the AI entry point; reinstall both fresh tweak dylibs/plists before evaluating model performance.

Device acceptance is intentionally user-supplied. CI and host tests prove indexing and bounded-core behavior only; they do not prove Core ML throughput, audio quality, route compatibility or thermal stability on an iPhone.

## Known limits

The public Core ML API does not expose per-prediction CPU/GPU/ANE provider counters, and iOS does not expose a public temperature-in-degrees API. Those fields are exported as unavailable with an explanation. Absolute track position is taken from public now-playing metadata when present; the measured audio timeline remains the sample index. If the route is neither 44.1 nor 48 kHz, the AI path stays in synchronized original fallback. A failed or late prediction cannot block Spotify; its exact epoch/sample range is logged and the next valid window may resume AI Live.

After a Spotify restart, a previously selected AI mode is restored only when the model has already passed verification; otherwise playback starts in Original and the UI requires an explicit AI-mode selection after readiness.
