# Third-party notices

Stringer's own code is MIT-licensed (see [LICENSE](LICENSE)). The app links
or downloads the following. The license texts of everything linked into the
binaries are copied into `Stringer.app/Contents/Resources/Licenses/` by
`build.sh`.

## Linked into the binaries

| Component | Used for | License |
|---|---|---|
| [webrtc-audio-processing](https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing) 2.1 | echo cancellation (AEC3) | BSD 3-Clause (WebRTC) |
| [Abseil](https://github.com/abseil/abseil-cpp) (pulled in by the above) | C++ support library | Apache 2.0 |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) 0.18.0 | speech recognition, diarization | Apache 2.0 |
| fastcluster, VBx, NeMo text processing (bundled by FluidAudio) | clustering, text normalisation | see FluidAudio's `ThirdPartyLicenses/` |

## Downloaded at runtime (`stringer setup`)

These models are not part of this repository or the app. They are fetched
from Hugging Face on first use and are governed by their own licenses; see
each model card.

- [Parakeet TDT 0.6B v3 (Core ML)](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml), derived from NVIDIA's Parakeet TDT 0.6B v3
- [Speaker diarization (Core ML)](https://huggingface.co/FluidInference/speaker-diarization-coreml), derived from pyannote Community-1
- [Parakeet CTC 110M (Core ML)](https://huggingface.co/FluidInference/parakeet-ctc-110m-coreml), for vocabulary rescoring

Meeting titles use Apple's on-device Foundation Models framework.
