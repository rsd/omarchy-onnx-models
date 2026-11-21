# omarchy-onnx-models

Four open person-segmentation models as checksummed ONNX files, with the recipe that builds them and Arch packages that install them. They are for programs that cut a person out of a camera frame, such as the ONNX cut-out module of omarchy-broadcast.

## What you get

- **Four Apache-2.0 models**: MediaPipe Selfie Segmentation (landscape), PP-HumanSeg v2 (mobile and lite) and MODNet.
- **One ONNX file per model**, built from the upstream release by a pinned recipe and published as a GitHub release asset with checksums. Programs and packages download the files by URL and check them against `SHA256SUMS`.
- **One Arch package per model**, `omarchy-onnx-model-<id>`. Each installs its file into `/usr/share/omarchy-onnx-models/`, a directory that belongs to no one program.
- **The licence and notice of every file**, including the modification notice that Apache-2.0 section 4(b) requires for the converted files.
- **The recipe**: the model table, the conversion scripts, the pinned environments and the offline tests. The model files themselves are never committed.

## Why use these files

- **You can check every file.** Each file has a SHA-256 in this README and in the release. The build fails if a result differs. [docs/release.md](docs/release.md#reproducibility) explains how.
- **You know what was changed.** The conversions change the file format, not the weights. [docs/models.md](docs/models.md) records the steps, the inputs and outputs, and the preprocessing of each model.
- **You know the licence status.** Each model's licence evidence and the known gaps in its training-data terms are written down.
- **No program owns the models.** Any program can read them from the shared directory, and you can install the packages in any combination. omarchy-broadcast's ONNX cut-out module depends on one package, its default model, and searches that directory.

## Install

```bash
yay -S omarchy-onnx-model-mediapipe-landscape
```

This is the default model of omarchy-broadcast. [INSTALL.md](INSTALL.md) covers the other packages, the check, the uninstall steps and how to rebuild the files.

## The models

All four are licensed under the Apache License, Version 2.0, by their authors.

| File | Size (bytes) | SHA-256 | Licence | Made from | Build check |
|---|---|---|---|---|---|
| `selfie_segmentation_landscape.onnx` | 449893 | `fa02222275c455638fa1190493b659d25ad31e86f1b6459f17bd501f02cbe43d` | Apache-2.0 | MediaPipe Selfie Segmentation (landscape), converted from TensorFlow Lite (opset 17) | verified equivalent |
| `pp_humansegv2_mobile_192x192.onnx` | 30166201 | `2bca11ec1f2a662146147d97523d613f5ef4ebf2a89803a95a0cbabfe2bd70a9` | Apache-2.0 | PP-HumanSeg v2 mobile (PaddleSeg), converted from a Paddle inference model | byte-identical |
| `pp_humansegv2_lite_192x192.onnx` | 12205830 | `ca96b4436f1ce6a76059e8902e20a9617f6829fb11f6c6c9e876563e6352e6b4` | Apache-2.0 | PP-HumanSeg v2 lite (PaddleSeg), converted from a Paddle inference model | byte-identical |
| `modnet_photographic.onnx` | 25888640 | `07c308cf0fc7e6e8b2065a12ed7fc07e1de8febb7dc7839d7b7f15dd66584df9` | Apache-2.0 | MODNet, the upstream ONNX export, unmodified | byte-identical |

**Byte-identical** files come out of every build with the same bytes, and the build checks their SHA-256. The MediaPipe conversion gives other bytes on every run (`tf2onnx` renames its folded constants). Its release file is a reference conversion with the SHA-256 above. Each build checks the supplied reference against that checksum, converts the original afresh and proves the two **equivalent**: the same weights exactly, the same operators, outputs within 1e-6. It ships the reference. See [docs/release.md](docs/release.md#reproducibility).

Each release also carries:

- `LICENSE-Apache-2.0`: the licence text;
- `NOTICE`: the attribution and modification notice of every file;
- `MANIFEST.toml`: per file, the size, SHA-256, upstream sources and their checksums, licence, how it was made and the exact tool versions;
- `SHA256SUMS`: the SHA-256 of every other file.

Inputs, outputs, preprocessing, upstream links, model cards and what is known about the training data are in [docs/models.md](docs/models.md). Read its training-data notes before you rely on a model: for PP-HumanSeg and MODNet they are not confirmed.

## Arch packages

| Package | Installs |
|---|---|
| `omarchy-onnx-model-mediapipe-landscape` | `selfie_segmentation_landscape.onnx` |
| `omarchy-onnx-model-pphumanseg-v2-mobile` | `pp_humansegv2_mobile_192x192.onnx` |
| `omarchy-onnx-model-pphumanseg-v2-lite` | `pp_humansegv2_lite_192x192.onnx` |
| `omarchy-onnx-model-modnet` | `modnet_photographic.onnx` |

[`packaging/arch/PKGBUILD`](packaging/arch/PKGBUILD) is one split recipe for the four packages. Each package installs its model into `/usr/share/omarchy-onnx-models/`, and its licence (`LICENSE`) and notice (`NOTICE`) into `/usr/share/licenses/<package>/`. The sources are the release's model files and the licence and notice files of the release tag, each pinned by SHA-256. Nothing is taken from a checkout. The packages are architecture independent (`arch=('any')`).

`pkgver` is the release tag without its `v`: `1.0.0` builds from `v1.0.0`. The packages follow each release (step 3 of [docs/release.md](docs/release.md)). [`scripts/srcinfo.sh`](scripts/srcinfo.sh) prepares the AUR recipe from this one.

## Repository layout

```
README.md, INSTALL.md, NOTICE
LICENSE-MIT, LICENSE-APACHE       the licence of this repository's own content
models.toml                       the model table: the single source of truth
requirements/                     the pinned environments: tflite.txt, paddle.txt, verify.txt,
                                  and their hashed lock files <name>.lock
convert/                          the conversion and verification programs (Python)
licenses/<id>/                    LICENSE and NOTICE of each model
packaging/arch/                   the Arch packages: one split PKGBUILD (see Arch packages)
scripts/build-models.sh           the build: downloads, converts, verifies, writes dist/
scripts/lock-requirements.sh      regenerates requirements/*.lock (docs/release.md)
scripts/lib/                      the shell and Python functions the build and the tests share
scripts/check-no-models.sh        the guard: refuses model files, archives and binaries in commits
scripts/test.sh                   runs every offline check
scripts/tests/                    the tests
.githooks/                        pre-commit, pre-merge-commit, pre-push: run the guard
docs/                             the models, the release procedure
```

## Testing

```bash
scripts/test.sh
```

The checks run without network and without the conversion environments. They need shellcheck, from `PATH`, from `SHELLCHECK=/path/to/shellcheck`, or run as `uvx --from shellcheck-py shellcheck` when `uvx` is installed. [docs/release.md](docs/release.md#what-the-tests-check) lists what they cover.

## Keeping models out of the history

`.gitignore` excludes `dist/`, `build/`, the environments and every model, archive and weight format. The guard `scripts/check-no-models.sh` refuses the same in a commit: model and archive extensions, anything under `dist/` or `build/` in any letter case, files over 1 MiB, and binary content. Enable the hooks in your clone:

```bash
git config core.hooksPath .githooks
```

`git commit --no-verify` bypasses the hooks, so the guard is a safety net, not an access control. `scripts/check-no-models.sh --all` checks the working tree. Model files are built into `dist/` and uploaded to a release by hand ([docs/release.md](docs/release.md)).

## Licences

- **This repository's content** (scripts, conversion programs, documentation, the model table) is MIT OR Apache-2.0, at your option: see [LICENSE-MIT](LICENSE-MIT) and [LICENSE-APACHE](LICENSE-APACHE).
- **The model files** in the releases are not covered by that licence. Each is under the licence of its upstream project, the Apache License, Version 2.0, with the attribution in [NOTICE](NOTICE) and [licenses/](licenses/). The MediaPipe and PP-HumanSeg files are modified files in the sense of the Apache License, section 4(b): their format was converted; their weights are unchanged. The MODNet file is unmodified.
- When you redistribute a model file, ship `LICENSE-Apache-2.0` and `NOTICE` with it.
- This is not legal advice.
