# AI Spatial — Stage 03: Accent Detector

Stage 03 adds an independent, local event-analysis path after Stage 02 has
produced synchronized vocals and instrumental frames and before JamesDSP. It
does not write to the render buffers, change the separator or alter JamesDSP.

## Architecture

```text
Stage 02 ASStreamOutput (epoch + absolute sample + vocals/instrumental)
  -> bounded serial Accent analysis queue
  -> 20 ms envelope / peak / flux / high-frequency features
  -> Vocal Event Analyzer and Instrumental Event Analyzer
  -> Context + adaptive thresholds + repetition/density suppression
  -> Accent Ranking Engine
  -> exact sample-index Event Scheduler
  -> Accent Trace diagnostics and future Spatial Engine input
```

The analysis worker receives copied synchronized stem frames from the existing
Stage 02 worker. The Spotify audio callback is not used for feature extraction,
classification, file I/O or UI work. At most eight analysis blocks are pending;
when that bound is reached optional detail is dropped and the reason is logged.
When a new stream epoch arrives, the schedule and per-source context are reset.
An in-flight old epoch cannot be published as a current event.

No lyric or speech-recognition dependency is used. A two-stem separator is not
treated as a reliable lead/back-vocal separator; `vocal_adlib_candidate` and
confidence values are explicitly marked as candidates.

## Event types

Vocal events: `vocal_phrase_start`, `vocal_attack`,
`vocal_syllable_ending`, `vocal_shout`, `vocal_adlib_candidate`, and
`vocal_pause_contrast`.

Instrumental events: `instrumental_attack`, `synth_insert`,
`percussion_contrast`, `sound_effect`, and `instrumental_pause_texture`.

Every event has `event_id`, `session_id`, `stream_epoch`, source, type,
`start_sample`, `end_sample`, duration, classification confidence,
expressiveness, priority, selected/rejected decision, decision reason,
`ready_deadline_sample`, deadline time, available sample at detection, window
ID, measured feature values, and detection latency. Sample indices are the
authoritative timeline; Spotify public metadata is never used as the only
position source.

The default ranking favours contextual contrast and rarity over loudness. It
uses adaptive local thresholds, a 350 ms minimum interval, periodic-hit
suppression, a ten-selected-events-per-minute ceiling, and a priority cutoff.
These are density controls rather than a quota: a quiet section can produce no
events, while a dense expressive section can contain several. If processing
passes the `ready_deadline_sample`, the candidate is retained as `rejected` with
`late_deadline` and never enters the future spatial schedule.

## Diagnostics and review

`Accent Trace` records feature rows, candidates, decisions, reasons, epoch
resets, overload drops and analysis latency through the existing bounded
diagnostics writer. It writes `accent-events.jsonl`, `accent-events.csv`, and an
`accent-summary.json` export; it never writes continuous PCM. The existing
Diagnostics export includes the two event files when a recording session is
active.

Open **AI Spatial → Accent Detector** to enable analysis, view candidate and
selected counts, type distribution, recent sample times, confidence, priority,
and rejection reasons. Each recent event can be labelled `successful`, `extra`,
or `missed`. A separate control records a user-reported missed event by sample
index/time and source. Export is available through the iOS share sheet.

## Tests

The host suite (`make -C ai_spatial test`) covers an isolated attack, repetitive
percussion suppression, late-deadline rejection, stream indexing and epoch
reset/ring behaviour. It uses synthetic signals and does not ship a music model.
The iPhone acceptance run must still include fast rap, melodic vocals,
instrumental material, dense beats, and adlib-heavy tracks. The user should
label recent events in Accent Detector and export the JSON/CSV together with
Detailed diagnostics. The 80% high-priority and 100 ms median timing criteria
are measured against that agreed manual set; CI cannot claim device or
subjective music quality without those exports.

## iPhone procedure

1. Install the Stage 03 `aispatial.dylib` and plist beside the existing Stage 02
   and JamesDSP files. Keep JamesDSP unchanged.
2. Verify the downloaded Stage 01 model, open **AI Spatial → Accent Detector**,
   and leave Accent Trace enabled. Use **AI Shadow** first so sound remains the
   original while events are produced.
3. Play each required track for at least two minutes. Check that event sample
   ranges are monotonic within an epoch, rejected repetitive hits explain why,
   and selected events are sparse. Exercise pause/resume, seek, track change,
   route change and Spotify restart; the epoch and recent schedule must reset.
4. Export Accent events and Detailed diagnostics. Compare selected events with a
   manual review and retain the exported files for the Stage 03 quality report.

The remote agent cannot access the physical iPhone or Mac. CI proves source
buildability and deterministic host logic; it does not prove Core ML throughput,
thermal behaviour, subjective selection quality or the 80%/100 ms device
acceptance targets.
