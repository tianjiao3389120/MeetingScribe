# Third-party software and models

MeetingScribe integrates with or downloads the following third-party projects.
Their licenses apply to those components and models; they are not relicensed by
MeetingScribe's MIT license.

| Component | Purpose | License / source |
| --- | --- | --- |
| whisper.cpp | Local speech transcription and VAD runtime | MIT — https://github.com/ggerganov/whisper.cpp |
| Whisper large-v3-turbo GGML model | Local transcription model | MIT model repository — https://huggingface.co/ggerganov/whisper.cpp |
| Silero VAD GGML model | Local voice activity detection | MIT model repository — https://huggingface.co/ggml-org/whisper-vad |
| sherpa-onnx | Local speaker diarization runtime | Apache-2.0 — https://github.com/k2-fsa/sherpa-onnx |
| pyannote segmentation model converted for sherpa-onnx | Speaker segmentation | Distributed with the sherpa-onnx speaker segmentation assets; review the upstream model and release terms before redistribution |
| 3D-Speaker CAMPPlus model | Speaker embedding | Apache-2.0 project — https://github.com/modelscope/3D-Speaker |

MeetingScribe downloads these components from their upstream locations and
verifies the exact artifacts it expects. A distributor must independently
confirm that its intended form of redistribution complies with every upstream
license and model term.

The current speaker runtime is pinned to `sherpa-onnx==1.13.4` and
`numpy==2.5.1`. Downloaded Whisper, VAD, segmentation, and embedding artifacts
are accepted only when their SHA-256 values match the constants in the source.
