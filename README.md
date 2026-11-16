# omarchy-onnx-models

ONNX files of four open person-segmentation models, built from the upstream releases by a pinned recipe and published as GitHub release assets with checksums. Packages and programs download them by URL and check them against `SHA256SUMS`. The Arch packages of this repository ([packaging/arch/](packaging/arch/)) are one such consumer; omarchy-broadcast's ONNX cut-out module depends on one of them (its default model) and searches the directory they install into.

This repository holds the recipe only: the model table, the conversion scripts, the licences and notices, the documentation and the tests. The model files themselves are never committed; they are built into `dist/` and uploaded to a release by hand (see [docs/release.md](docs/release.md)).

## The models

All four are licensed under the Apache License, Version 2.0, by their authors.

| File | Size (bytes) | SHA-256 | Licence | Made from | Build check |
|---|---|---|---|---|---|
| `selfie_segmentation_landscape.onnx` | 449893 | `fa02222275c455638fa1190493b659d25ad31e86f1b6459f17bd501f02cbe43d` | Apache-2.0 | MediaPipe Selfie Segmentation (landscape), converted from TensorFlow Lite (opset 17) | verified equivalent |
| `pp_humansegv2_mobile_192x192.onnx` | 30166201 | `2bca11ec1f2a662146147d97523d613f5ef4ebf2a89803a95a0cbabfe2bd70a9` | Apache-2.0 | PP-HumanSeg v2 mobile (PaddleSeg), converted from a Paddle inference model | byte-identical |
| `pp_humansegv2_lite_192x192.onnx` | 12205830 | `ca96b4436f1ce6a76059e8902e20a9617f6829fb11f6c6c9e876563e6352e6b4` | Apache-2.0 | PP-HumanSeg v2 lite (PaddleSeg), converted from a Paddle inference model | byte-identical |
| `modnet_photographic.onnx` | 25888640 | `07c308cf0fc7e6e8b2065a12ed7fc07e1de8febb7dc7839d7b7f15dd66584df9` | Apache-2.0 | MODNet, the upstream ONNX export, unmodified | byte-identical |

**Byte-identical** files come out of every build with the same bytes, and the build checks their SHA-256. The MediaPipe conversion gives other bytes on every run (`tf2onnx` renames its folded constants), so its release file is a reference conversion with the SHA-256 above: each build checks the supplied reference against that checksum, converts the original afresh, proves the two **equivalent** (the same weights exactly, the same operators, outputs within 1e-6) and ships the reference. See [docs/release.md](docs/release.md#reproducibility).

Each release also carries `LICENSE-Apache-2.0` (the licence text), `NOTICE` (the attribution and modification notice of every file), `MANIFEST.toml` (per file: size, SHA-256, upstream sources and their checksums, licence, how it was made, the exact tool versions) and `SHA256SUMS`.

Inputs, outputs, preprocessing, upstream links, model cards and what is known about the training data are in [docs/models.md](docs/models.md). Read the training-data notes there before relying on a model: for PP-HumanSeg and MODNet they are not confirmed.

## Quick start

Building needs [uv](https://docs.astral.sh/uv/), `curl`, `unzip`, `sha256sum`, `git` and Python 3.11 or newer as `python3`. uv fetches the pinned Python interpreters and packages itself.

```bash
scripts/build-models.sh --reference-dir <dir>   # downloads, converts, verifies; writes dist/
(cd dist && sha256sum -c SHA256SUMS)
scripts/test.sh                                 # the offline checks of this repository
```

`<dir>` holds `selfie_segmentation_landscape.onnx`, the MediaPipe file of the latest release (`gh release download <tag> --pattern selfie_segmentation_landscape.onnx --dir <dir>`); without it the build stops and explains. `scripts/build-models.sh` downloads each original from its pinned URLs and checks its SHA-256 before using it (a download with another SHA-256, such as an HTML quota page, is discarded and the next URL tried), converts it in a virtual environment whose every package is pinned exactly and installed from a hashed lock file, from PyPI only (`requirements/`), checks the result with `onnx.checker` and a CPU inference in ONNX Runtime, and fails when the result's SHA-256 differs from the one in `models.toml` (for MediaPipe: when the reference's SHA-256 differs, or when the fresh conversion is not equivalent to it). The work directory (`build/work.*`) and the environments are removed at the end; `--keep-work` and `--keep-venvs` keep them. Other options: `--only <id>`, `--input-dir <dir>` (use originals downloaded before, still checksummed; useful because the PP-HumanSeg host, `paddleseg.bj.bcebos.com`, can be very slow), `--accept-new-checksums`, `--dist <dir>`. The build writes into `dist/` (or `--dist <dir>`) only when it is absent, empty, or carries the marker file `.omarchy-onnx-models-dist` that the build writes there; any other directory is refused and left untouched. The marker is not a release file. The run log is `build/build-models.log`.

A full build downloads about 70 MB of originals and, through uv, about 1 GB of Python packages (TensorFlow and PaddlePaddle) unless they are in uv's cache.

## Arch packages

[`packaging/arch/PKGBUILD`](packaging/arch/PKGBUILD) is one split recipe for four Arch packages, one per model. Each package downloads its model file from the release and installs it into `/usr/share/omarchy-onnx-models/`. That directory belongs to no one program: any program may read the models from it, and the packages can be installed in any combination.

| Package | Installs |
|---|---|
| `omarchy-onnx-model-mediapipe-landscape` | `selfie_segmentation_landscape.onnx` |
| `omarchy-onnx-model-pphumanseg-v2-mobile` | `pp_humansegv2_mobile_192x192.onnx` |
| `omarchy-onnx-model-pphumanseg-v2-lite` | `pp_humansegv2_lite_192x192.onnx` |
| `omarchy-onnx-model-modnet` | `modnet_photographic.onnx` |

Each package also installs the licence (`LICENSE`) and the notice (`NOTICE`) of its model into `/usr/share/licenses/<package>/`. The sources are the release's model files and the licence and notice files of the release tag, each pinned by SHA-256; nothing is taken from a checkout. The packages are architecture independent (`arch=('any')`). The AUR recipe is prepared from this one by [`scripts/srcinfo.sh`](scripts/srcinfo.sh) (see [docs/release.md](docs/release.md)).

Build from a clone of this repository, then install the packages you want:

```bash
cd packaging/arch
makepkg                                                # downloads and checks the sources
sudo pacman -U omarchy-onnx-model-modnet-*.pkg.tar.zst  # one package, or several
```

`pkgver` is the release tag without its `v`, so `1.0.0` builds from `v1.0.0`. The downloads and the packages stay in `packaging/arch/`, which its `.gitignore` excludes from git. The packages follow each release: see step 3 of [docs/release.md](docs/release.md).

## Repository layout

```
README.md, NOTICE
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

This runs without network and without the conversion environments: shellcheck over every shell script and hook, `bash -n`, the model table's consistency (every field, the checksums, the licence files, and the tables in this README and in `docs/models.md`), the Arch recipe against the model table and the licence files (`scripts/tests/pkgbuild-test.sh`: the ids, the file names, the SHA-256 of the model files, and the SHA-256 of the licence and notice files as they are at the tag of its `pkgver` when that tag is present locally), the checksum, manifest and download functions of the build against small fake files, the reference-file handling of the build (with a fake `uv` that stops it before any environment), whole builds with a fake `uv` and fake interpreters (the uv options, a checksum mismatch or a wrong `--input-dir` file leaving `dist/` untouched, the `--dist` marker, `--keep-venvs`), the lock files against `requirements/*.txt`, the equivalence check against fake summaries, the guard's own tests and the guard over the whole tree. It needs shellcheck: from `PATH`, from `SHELLCHECK=/path/to/shellcheck`, or, when `uvx` is installed, run as `uvx --from shellcheck-py shellcheck`.

## Keeping models out of the history

`.gitignore` excludes `dist/`, `build/`, the environments and every model, archive and weight format. The guard `scripts/check-no-models.sh` refuses the same in a commit (model and archive extensions, anything under `dist/` or `build/` in any letter case, files over 1 MiB, binary content). Enable the hooks in your clone with:

```bash
git config core.hooksPath .githooks
```

`git commit --no-verify` bypasses them, so the guard is a safety net, not an access control. `scripts/check-no-models.sh --all` checks the working tree.

## Licences

- **This repository's content** (scripts, conversion programs, documentation, the model table) is MIT OR Apache-2.0, at your option: see [LICENSE-MIT](LICENSE-MIT) and [LICENSE-APACHE](LICENSE-APACHE).
- **The model files** in the releases are not covered by that licence. Each is under the licence of its upstream project, the Apache License, Version 2.0, with the attribution in [NOTICE](NOTICE) and [licenses/](licenses/). The MediaPipe and PP-HumanSeg files are modified files in the sense of the Apache License, section 4(b): their format was converted; their weights are unchanged. The MODNet file is unmodified.
- When you redistribute a model file, ship `LICENSE-Apache-2.0` and `NOTICE` with it.
- This is not legal advice.
