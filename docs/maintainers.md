# Maintaining the repository

This page is for people who change the recipe, rebuild the files or prepare a release. You do not need it to install or use the models (see [INSTALL.md](../INSTALL.md)). The release procedure is in [release.md](release.md).

## Repository layout

```
README.md, INSTALL.md, NOTICE
LICENSE-MIT, LICENSE-APACHE       the licence of this repository's own content
models.toml                       the model table: the single source of truth
requirements/                     the pinned environments: tflite.txt, paddle.txt, verify.txt,
                                  and their hashed lock files <name>.lock
convert/                          the conversion and verification programs (Python)
licenses/<id>/                    LICENSE and NOTICE of each model
packaging/arch/                   the Arch packages: one split PKGBUILD (see INSTALL.md)
scripts/build-models.sh           the build: downloads, converts, verifies, writes dist/
scripts/lock-requirements.sh      regenerates requirements/*.lock (docs/release.md)
scripts/lib/                      the shell and Python functions the build and the tests share
scripts/check-no-models.sh        the guard: refuses model files, archives and binaries in commits
scripts/test.sh                   runs every offline check
scripts/tests/                    the tests
.githooks/                        pre-commit, pre-merge-commit, pre-push: run the guard
docs/                             the models, this page, the release procedure
```

## Run the tests

```bash
scripts/test.sh
```

The checks run without network and without the conversion environments. They need shellcheck: on `PATH`, at the path in `SHELLCHECK`, or fetched with `uvx` when `uvx` is installed. To name the program yourself:

```bash
SHELLCHECK=/path/to/shellcheck scripts/test.sh
```

[release.md](release.md#what-the-tests-check) lists what the tests cover.

## Keep models out of the history

`.gitignore` excludes `dist/`, `build/`, the environments and every model, archive and weight format. The guard `scripts/check-no-models.sh` refuses the same in a commit: model and archive extensions, anything under `dist/` or `build/` in any letter case, files over 1 MiB, and binary content. Enable the hooks in your clone:

```bash
git config core.hooksPath .githooks
```

`git commit --no-verify` bypasses the hooks, so the guard is a safety net, not an access control. To check the working tree yourself, run:

```bash
scripts/check-no-models.sh --all
```

Model files are built into `dist/` and uploaded to a release by hand ([release.md](release.md)).

## Rebuild the files

You do not need this to use the models. It converts the files again from the upstream originals, to check the recipe or to prepare a release.

Before you start:

- [uv](https://docs.astral.sh/uv/), `curl`, `unzip`, `sha256sum`, `git` and Python 3.11 or newer as `python3`. uv fetches the pinned Python interpreters and packages itself.
- About 70 MB of downloads for the originals and, through uv, about 1 GB of Python packages (TensorFlow and PaddlePaddle) unless they are in uv's cache.
- The MediaPipe reference file, `selfie_segmentation_landscape.onnx` from the latest release. Without it the build stops and explains.

Steps:

1. Clone the repository.

   ```bash
   git clone https://github.com/rsd/omarchy-onnx-models.git
   cd omarchy-onnx-models
   ```

2. Download the reference file into a directory of your choice.

   ```bash
   gh release download <tag> --pattern selfie_segmentation_landscape.onnx --dir <dir>
   ```

3. Build, check the result and run the offline tests.

   ```bash
   scripts/build-models.sh --reference-dir <dir>   # downloads, converts, verifies; writes dist/
   (cd dist && sha256sum -c SHA256SUMS)
   scripts/test.sh                                 # the offline checks of this repository
   ```

   `sha256sum -c` prints `OK` for every file in `dist/`.

### What the build does

`scripts/build-models.sh` runs these steps for each model:

1. It downloads the original from its pinned URLs and checks its SHA-256. A download with another SHA-256, such as an HTML quota page, is discarded and the next URL is tried.
2. It converts the original in a virtual environment whose every package is pinned exactly and installed from a hashed lock file, from PyPI only (`requirements/`).
3. It checks the result with `onnx.checker` and a CPU inference in ONNX Runtime.
4. It fails when the result's SHA-256 differs from the one in `models.toml`. For MediaPipe it fails when the reference's SHA-256 differs, or when the fresh conversion is not equivalent to the reference.

The work directory (`build/work.*`) and the environments are removed at the end. The run log is `build/build-models.log`.

### Build options

| Option | Effect |
|---|---|
| `--reference-dir <dir>` | The directory with the MediaPipe reference file |
| `--only <id>` | Build one model |
| `--input-dir <dir>` | Use originals downloaded before, still checksummed. Useful because the PP-HumanSeg host, `paddleseg.bj.bcebos.com`, can be very slow |
| `--accept-new-checksums` | Without a reference file, build the fresh MediaPipe file, report its SHA-256 as a mismatch and write it to `dist/`. It never rewrites `models.toml` |
| `--dist <dir>` | Write to another directory than `dist/` |
| `--keep-work`, `--keep-venvs` | Keep the work directory or the environments |

The build writes into `dist/` (or `--dist <dir>`) only when it is absent, empty, or carries the marker file `.omarchy-onnx-models-dist` that the build writes there. It refuses any other directory and leaves it untouched. The marker is not a release file.

Why the MediaPipe file needs a reference, and how the build proves equivalence: [release.md](release.md#reproducibility). The release procedure: [release.md](release.md).
