# Stringer

[![build](https://github.com/sajaysurya/stringer/actions/workflows/build.yml/badge.svg)](https://github.com/sajaysurya/stringer/actions/workflows/build.yml)

Records a meeting's **microphone** and **system audio** as two tracks and
transcribes them **on-device**: a live `Me` / `Them` transcript while you
talk, then a diarized final transcript (`Mic N` / `Speaker N`) with an Apple
Intelligence title. Nothing leaves the Mac once the models are downloaded.

## Install

Download the DMG from the [latest release](https://github.com/sajaysurya/stringer/releases/latest),
drag Stringer to Applications, then once (the app is not notarized):

```sh
xattr -dr com.apple.quarantine /Applications/Stringer.app
```

Open it: it lives in the menu bar and downloads its speech models (~600 MB,
once). The first recording asks for Microphone and System Audio access.
Releases are signed with the same certificate, so these grants survive
upgrades.

## Requirements

- macOS 26 or later on Apple silicon (built and tested on macOS 27.2, M3 Pro)
- Xcode or the Command Line Tools (Swift 6.2+)
- Apple Intelligence on, for titles (optional)
- Python 3 and `uv` (or `pip`), only to build the echo canceller's meson/ninja into `.venv-build/`

## Build from source

```sh
./setup-signing.sh     # once: a self-signed "Stringer Local Signing" identity
./build.sh             # release build into bin/
bin/stringer setup     # once: download the speech models (~600 MB), then offline
open bin/Stringer.app  # the menu-bar app
```

`setup-signing.sh` creates its own keychain
(`~/Library/Keychains/stringer-signing.keychain-db`) and leaves your keychain
search list alone (`build.sh` passes `--keychain`). Without it, builds are
signed ad-hoc and macOS asks for microphone and system-audio access again
after every build.

`./package.sh` builds `dist/Stringer-<version>.dmg`.

### CI and releases

Every push and pull request builds, tests and packages on GitHub Actions
(`.github/workflows/build.yml`); the DMG is attached to the run. Pushing a
tag `vX.Y.Z` (matching `stringerVersion` in `Sources/StringerCore/Files.swift`)
publishes a release.

CI signs with the repository secrets `SIGNING_P12` (the identity, base64) and
`SIGNING_P12_PASSWORD`; without them it builds ad-hoc. To use your own:

```sh
STRINGER_P12_PASSWORD=$(openssl rand -hex 24) ./setup-signing.sh --export-p12 id.p12   # on a fresh machine
gh secret set SIGNING_P12 < <(base64 -i id.p12)
gh secret set SIGNING_P12_PASSWORD --body "$STRINGER_P12_PASSWORD"
rm id.p12
```

## Use

From the menu bar: **Start Recording** (⌘R), **Stop Recording** (⌘S). When
a meeting app (Zoom, Teams, Slack, FaceTime, Webex, or Meet in a browser)
starts using the microphone, Stringer asks whether to record; a recording
started that way stops itself 30 s after the call releases the mic.

From a terminal:

```
stringer rec [--title T]          record in this terminal; Ctrl-C stops and transcribes
stringer start / stop             record in the background
stringer status [--json]          what is recording or transcribing
stringer tail                     follow the live transcript
stringer ls                       list meetings
stringer note [MEETING]           re-transcribe from the audio (recovers interrupted meetings)
stringer rename [MEETING] TITLE
stringer config [set KEY VALUE]   settings: flags > STRINGER_* env > ~/.config/stringer/config.toml > defaults
stringer setup                    download the models once
stringer doctor                   binaries, signing, permissions, models, Apple Intelligence
stringer devices                  audio devices and which apps are using a mic (diagnostic)
stringer transcribe FILE.wav      one file through the recogniser (diagnostic)
```

Settings: `home` (default `~/Meetings`), `vault` (copy transcripts as `.md`
into e.g. an Obsidian folder), `mic` (`default` | `all` | `none`), `asr`
(`parakeet` | `apple`), `diarize`, `speakers` (exact count per track, 0 =
auto), `cluster_threshold`, `chunk` (live slice seconds), `live`, `vocab`
(a file of terms, one per line — keep it short and unusual), `debug` (keep
audio and logs), `ai_title`, `detect` (ask to record detected meetings).

Each meeting is a folder `YYYY-MM-DD HHMM - Title` holding `live.txt`,
`transcript.txt` and `meeting.json` (its stable ID). With `debug` on, the
audio (`mic.wav`, `system.wav`), `capture.log`, `capture.json`, `worker.log`
and `final.json` are kept too.

## Layout

```
Sources/
  CStringerAEC/      C API over WebRTC AEC3 (static lib built by aec/build.sh)
  StringerCore/      file names, WAV I/O, atomic writes, Core Audio queries
  CaptureKit/        process tap, microphones, 16 kHz timeline, echo canceller
  StringerKit/       settings, meeting store, lifecycle, status snapshot
  StringerPipeline/  recognition, diarization, live + final transcripts, titles, owner, doctor
  stringer/          the CLI
  StringerRecorder/  Stringer Recorder.app — capture only, launched via LaunchServices
  StringerApp/       Stringer.app — the menu bar (a UI only; never owns a recording)
  stringer-title/    FoundationModels title helper
  aec-offline/       replay a kept recording through the echo canceller
Tests/StringerTests/ unit tests (swift-testing)
scripts/             test.sh, lifecycle-test.sh, make-test-audio.py
```

## Develop

```sh
scripts/test.sh            # unit tests, then the lifecycle criteria on bin/
scripts/test.sh --unit     # unit tests only
```

The recorder can replay files instead of capturing, which exercises the whole
pipeline (resampling, timeline, AEC, live and final transcripts, titles)
without permissions or playing anything aloud:

```sh
python3 scripts/make-test-audio.py /tmp/fx
STRINGER_REPLAY_SYSTEM=/tmp/fx/system.wav STRINGER_REPLAY_MIC=/tmp/fx/mic.wav \
  STRINGER_HOME=/tmp/meetings bin/stringer rec
```

Synthetic `say` speech is for smoke tests only; it misleads diarization and
vocabulary conclusions in both directions.

## How it works

- **System audio** comes from one global Core Audio process tap, in a private
  aggregate device clocked by the built-in speakers. The tap hears every app
  wherever its sound is routed; the clock device only supplies a clock.
- **The microphone** follows the system default input (AirPods, the lid
  closing). Virtual loopback devices (Zoom, Teams) are never used as mics.
- Both tracks are resampled to 16 kHz per source and placed on one timeline
  by wall clock, which echo cancellation needs.
- **Echo cancellation** is WebRTC AEC3 on the mic track, with the system track
  as the reference. Never Apple's Voice Processing I/O: it ducks every other
  app's audio, which the tap then records.
- **Permissions** belong to a signed app bundle launched through
  LaunchServices, so capture runs in `Stringer Recorder.app`, never in a
  terminal process (which records silence, without an error).
- **Transcription** is Parakeet TDT v3 via FluidAudio on the Neural Engine;
  speakers are diarized per track (Pyannote Community-1 + VBx), so `Mic N`
  and `Speaker N` are separate namespaces.
- **Files are the protocol** between processes. One owner process per meeting
  writes its state; meetings are identified by a stable ID, not by folder.

## License

MIT — see [LICENSE](LICENSE). Third-party components and models:
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
