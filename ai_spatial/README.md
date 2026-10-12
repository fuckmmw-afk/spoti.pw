# AI Spatial add-on

Stage 04 **builds B–F** add deterministic event extraction with attack/release
envelopes, six bounded motion types, headphone binaural, speaker, universal
stereo and mono-safe renderers, route/profile selection, selective foreground
delta mixing, live integration, and the unified croma settings page. Build A's
clock accounting, deadlines and stale/duplicate event gating remain the timing
foundation.
See [Stage 04 build notes](../deliverable/AI-Spatial-Stage04.md).

Build A keeps the existing Stage 03 UI and the Separator/JamesDSP audio path.
The neural model is downloaded by the user from Hugging Face and is never
included in source or artifacts. Legacy setup is described in
[Stage 02](../deliverable/AI-Spatial-Stage02.md) and
[Stage 03](../deliverable/AI-Spatial-Stage03.md).

## Diagnostics

Open **AI Spatial → Diagnostics**. The level is persisted locally:

- **Basic** records errors, session boundaries, unavailable capabilities and final summaries.
- **Detailed** additionally records every stage, every inference window, per-second `ai-spatial-timeline.csv`, tensor statistics, timestamps, queue counters and reconstruction checks.
- **Full Trace** adds bounded binary dumps. It retains the first five seconds and the current anomalous window when detected, with a 48 MiB cap and a 90-second session limit. Numeric arrays are never printed into the text log.

The writer is asynchronous with a bounded event/byte queue. There is no synchronous file write or large text conversion in the AudioUnit callback. If the queue fills, `dropped_events` is recorded. Full Trace is opt-in and can be stopped from the Diagnostics page.

Normal report export produces:

- `ai-spatial-diagnostics.log` — JSON-line stage events with human-readable fields;
- `ai-spatial-timeline.csv` — one row per second, including RMS/peak, stem levels, reconstruction error, window counts, inference min/average/max/p95, queue and memory measurements;
- `ai-spatial-metadata.json` — session, model revision and manifest hashes, Core ML contract, STFT settings, PCM format, limits, counters and explicit unavailable reasons.
- The export also includes the requested stable names `spatial-diagnostics.log`, `spatial-events.jsonl`, `spatial-summary.json`, and `spatial-timeline.csv`.
- Full Trace additionally exports bounded local `spatial-clips/Original.wav`,
  `Spatial.wav`, `Difference.wav`, and `Event-Foreground.wav` A/B clips.

The optional **Export Full Trace debug ZIP** contains only the selected `.bin`/`.wav`/sidecar files and the reports. It does not include the original filename, Spotify tokens or credentials. Full Trace may retain the first five seconds of Spotify PCM as a canonical float32 copy: the callback only copies into a preallocated bounded memory ring, and the writer persists it asynchronously. Basic and Detailed levels remain metrics-only for live Spotify audio. The offline test can retain selected PCM, output WAVs and tensor windows under Full Trace.

The legacy Stage 01 post-render observer remains metrics-only when the bridge is unavailable. With the Stage 02 bridge loaded, the same pre-JamesDSP callback feeds the bounded stream and the observer avoids a duplicate capture. Detailed and Full Trace add per-second input/stem rows for the streaming path and retain a bounded canonical PCM copy. If the Spotify build does not expose `AudioOutputUnitStart`, the report says `unavailable` and continues with the local-file test. Per-provider CPU/GPU/ANE counters are unavailable from Core ML in this injected process and are labelled as such.

To collect Stage 01 while Spotify is playing, open **Diagnostics**, select Detailed or Full Trace, press **Start diagnostics**, return to playback for the required interval, then press **Stop diagnostics**. Run **Test first 30 seconds** separately to populate Stages 02–10. The resulting session distinguishes the realtime Spotify blocks from the offline picker input instead of combining them.

## Offline test

**Test first 30 seconds** reads the first 30 seconds (or the entire shorter file), converts to 44.1 kHz float32 stereo, and runs 2-second windows (2048-point periodic-Hann STFT, 441-sample hop, reflected boundaries) with the model's fixed `[1,2050,201,2]` contract. Dimension 1 interleaves the two channels for each frequency bin and dimension 3 stores the real/imaginary pair. The model output is decoded as a complex vocal spectrum; the packed `vDSP_fft_zrip` inverse is scaled by `1/(2N)` and its squared-Hann weight is removed before overlap blending. `instrumental` is then computed as the original PCM minus the overlap-added vocals. The trace measures input preparation, windowing, STFT, Core ML input/output, inverse STFT, residual reconstruction, overlap blending, per-second levels and the RMS difference between `vocals + instrumental` and the source.

This offline path never installs an AudioUnit processing callback and never changes JamesDSP settings or buffers. It is the safe way to validate the downloaded model. Anomalies are labelled as measured values, derived calculations or heuristic warnings; a float sample above ±1 is recorded as a conversion/playback risk, not automatically treated as proof of failure.

## Model and build

The loader downloads the ANE model from [My-Name-Is-Jeff/vitrine-sing](https://huggingface.co/My-Name-Is-Jeff/vitrine-sing), revision `f17db769d3dc066f4690e842f058a34b00593252`. The runtime checks the five published file sizes and SHA-256 values, verifies the Core ML contract and requests `MLComputeUnitsCPUAndNeuralEngine`. No `.mlmodel`, `.mlmodelc`, `.mlpackage`, `weight.bin`, IPA or model cache is stored in this repository or GitHub Actions artifact.

```sh
PATH=/tmp/chroma-tools:$PATH THEOS=/root/theos make -C ai_spatial clean stage
# Host-only bounded-ring/index tests (also run in GitHub Actions)
PATH=/tmp/chroma-tools:$PATH THEOS=/root/theos make -C ai_spatial test
```

Inject the staged `aispatial.dylib` and `aispatial.plist` alongside the existing Spotify/Croma tweak. Do not change or replace the JamesDSP files.
