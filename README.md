# omarchy-onnx-models

Open person-segmentation models as plain ONNX files for any Linux distribution, with checksums, licences and Arch packages.

ONNX (Open Neural Network Exchange) is a standard file format for trained models. These four models cut a person out of a camera frame, as in the open-model cut-out of [omarchy-broadcast](https://github.com/rsd/omarchy-broadcast). The files work with any program that runs ONNX models. The packages are for Arch Linux and Omarchy.

## What you get

- **Four Apache-2.0 models**: MediaPipe Selfie Segmentation (landscape), PP-HumanSeg v2 (mobile and lite) and MODNet.
- **One ONNX file per model**, built from the upstream release by a pinned recipe and published as a GitHub release asset with checksums. Programs and packages download the files by URL and check them against `SHA256SUMS`.
- **One Arch package per model**, `omarchy-onnx-model-<id>`. Each installs its file into `/usr/share/omarchy-onnx-models/`, a directory that belongs to no one program.
- **The licence and notice of every file**, including the modification notice that Apache-2.0 section 4(b) requires for the converted files.
- **The recipe**: the model table, the conversion scripts, the pinned environments and the offline tests. The model files themselves are never committed.

## Why use these files

- **You can check every file.** Each file has a SHA-256 in this README and in the release. The build fails when the SHA-256 of a result differs. [docs/release.md](docs/release.md#reproducibility) explains how.
- **You know what was changed.** The conversions change the file format, not the weights. [docs/models.md](docs/models.md) records the steps, the inputs and outputs, and the preprocessing of each model.
- **You know the licence status.** Each model's licence evidence and the known gaps in its training-data terms are written down.
- **No program owns the models.** Any program can read the files, and you can install the packages in any combination. The omarchy-broadcast ONNX cut-out module depends on one package, its default model, and searches that directory.

## Install

On Arch Linux or Omarchy, install a package from the AUR (the Arch User Repository). This is the default model of omarchy-broadcast:

```bash
yay -S omarchy-onnx-model-mediapipe-landscape
```

On any other Linux distribution, download a file from the [v1.0.0 release](https://github.com/rsd/omarchy-onnx-models/releases/tag/v1.0.0) (change the tag for a newer one), check it, and put it where your program looks. For omarchy-broadcast that is `~/.local/share/omarchy-broadcast/models/onnx/`:

```bash
mkdir -p ~/.local/share/omarchy-broadcast/models/onnx
cd ~/.local/share/omarchy-broadcast/models/onnx
base=https://github.com/rsd/omarchy-onnx-models/releases/download/v1.0.0
curl -fLO "$base/selfie_segmentation_landscape.onnx" -O "$base/LICENSE-Apache-2.0" -O "$base/NOTICE" -O "$base/SHA256SUMS"
sha256sum --ignore-missing -c SHA256SUMS
```

[INSTALL.md](INSTALL.md) has the other packages, the other directories omarchy-broadcast searches, the checks and the uninstall steps. To run the files you need ONNX Runtime. omarchy-broadcast needs version 1.29 or newer: see [omarchy-onnxruntime](https://github.com/rsd/omarchy-onnxruntime) and the daemon's [ONNX setup guide](https://github.com/rsd/omarchy-broadcast/blob/main/docs/setup/onnx.md).

## The models

All four are licensed under the Apache License, Version 2.0, by their authors.

| File | Size (bytes) | SHA-256 | Licence | Made from |
|---|---|---|---|---|
| `selfie_segmentation_landscape.onnx` | 449893 | `fa02222275c455638fa1190493b659d25ad31e86f1b6459f17bd501f02cbe43d` | Apache-2.0 | MediaPipe Selfie Segmentation (landscape), converted from TensorFlow Lite (opset 17) |
| `pp_humansegv2_mobile_192x192.onnx` | 30166201 | `2bca11ec1f2a662146147d97523d613f5ef4ebf2a89803a95a0cbabfe2bd70a9` | Apache-2.0 | PP-HumanSeg v2 mobile (PaddleSeg), converted from a Paddle inference model |
| `pp_humansegv2_lite_192x192.onnx` | 12205830 | `ca96b4436f1ce6a76059e8902e20a9617f6829fb11f6c6c9e876563e6352e6b4` | Apache-2.0 | PP-HumanSeg v2 lite (PaddleSeg), converted from a Paddle inference model |
| `modnet_photographic.onnx` | 25888640 | `07c308cf0fc7e6e8b2065a12ed7fc07e1de8febb7dc7839d7b7f15dd66584df9` | Apache-2.0 | MODNet, the upstream ONNX export, unmodified |

Each release also carries `LICENSE-Apache-2.0` (the licence text), `NOTICE` (the attribution and modification notice of every file), `MANIFEST.toml` (per file: size, SHA-256, upstream sources, licence, how it was made, tool versions) and `SHA256SUMS` (the SHA-256 of every other file). Inputs, outputs, preprocessing and upstream links are in [docs/models.md](docs/models.md).

## Known gaps

- The training-data terms of PP-HumanSeg and MODNet are not confirmed. Read the training-data notes in [docs/models.md](docs/models.md) before you rely on them.
- The checks prove that each file loads and runs. No benchmark measures segmentation quality.
- The MediaPipe file is a reference conversion, not byte-reproducible. The build proves a fresh conversion equivalent to it ([docs/release.md](docs/release.md#reproducibility)).

## Maintainers

The repository layout, the tests, the guard against committed models and the rebuild steps are in [docs/maintainers.md](docs/maintainers.md). The release procedure is in [docs/release.md](docs/release.md).

## Licences

- **This repository's content** (scripts, conversion programs, documentation, the model table) is MIT OR Apache-2.0, at your option: see [LICENSE-MIT](LICENSE-MIT) and [LICENSE-APACHE](LICENSE-APACHE).
- **The model files** in the releases are not covered by that licence. Each is under the licence of its upstream project, the Apache License, Version 2.0, with the attribution in [NOTICE](NOTICE) and [licenses/](licenses/). The MediaPipe and PP-HumanSeg files are modified files in the sense of the Apache License, section 4(b): their format was converted; their weights are unchanged. The MODNet file is unmodified.
- When you redistribute a model file, ship `LICENSE-Apache-2.0` and `NOTICE` with it.
- This is not legal advice.
