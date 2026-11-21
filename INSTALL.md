# Install the models

Install the Arch packages of the ONNX models from the AUR. Each package puts one model file into `/usr/share/omarchy-onnx-models/`. The default model for omarchy-broadcast is `omarchy-onnx-model-mediapipe-landscape`. You do not need to install it by hand when you install the omarchy-broadcast ONNX module, because that package depends on it.

## Before you start

- Omarchy or Arch Linux, an AUR helper such as `yay`, and `sudo`.
- About 70 MB of free disk. The four packages share one recipe, so building any one of them downloads the files of all four models.

## Install the default model

1. Install the package.

   ```bash
   yay -S omarchy-onnx-model-mediapipe-landscape
   ```

   The package downloads its file from the `v1.0.0` release and refuses a file whose SHA-256 differs from the one in the recipe.

2. Install more models if you want to choose them. Each package is independent, so install any combination.

   ```bash
   yay -S omarchy-onnx-model-pphumanseg-v2-mobile omarchy-onnx-model-pphumanseg-v2-lite omarchy-onnx-model-modnet
   ```

| Package | Installs | Made from |
|---|---|---|
| `omarchy-onnx-model-mediapipe-landscape` (default) | `selfie_segmentation_landscape.onnx` | MediaPipe Selfie Segmentation (landscape) |
| `omarchy-onnx-model-pphumanseg-v2-mobile` | `pp_humansegv2_mobile_192x192.onnx` | PP-HumanSeg v2 mobile |
| `omarchy-onnx-model-pphumanseg-v2-lite` | `pp_humansegv2_lite_192x192.onnx` | PP-HumanSeg v2 lite |
| `omarchy-onnx-model-modnet` | `modnet_photographic.onnx` | MODNet |

All four packages come from one AUR base, `omarchy-onnx-models`, and the packages are architecture independent. [docs/models.md](docs/models.md) describes each model, and its training-data notes say what is not confirmed.

## Check that it works

List the files a package installed:

```bash
pacman -Ql omarchy-onnx-model-mediapipe-landscape
```

The list shows `/usr/share/omarchy-onnx-models/selfie_segmentation_landscape.onnx`, and `LICENSE` and `NOTICE` in `/usr/share/licenses/omarchy-onnx-model-mediapipe-landscape/`.

Check the installed files against the release's checksums:

```bash
curl -sL https://github.com/rsd/omarchy-onnx-models/releases/download/v1.0.0/SHA256SUMS \
    | (cd /usr/share/omarchy-onnx-models && sha256sum --ignore-missing -c)
```

Each installed model prints `<file>: OK`. Files you did not install are skipped. Use the tag that matches the package version (`pacman -Q omarchy-onnx-model-mediapipe-landscape` shows it, `1.0.0` for `v1.0.0`).

## Uninstall

```bash
sudo pacman -R omarchy-onnx-model-<id>      # for each model package you installed
```

If the omarchy-broadcast ONNX module is installed, it depends on the default model: remove the module first, or use `pacman -Rs` on it.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| The build stops with a failed checksum | A downloaded file differs from the SHA-256 in the PKGBUILD, for example a truncated or replaced download | Clear your AUR helper's cache and build again. A published asset is never replaced, so a mismatch that persists is an error to report |
| A program does not find the model | It searches other directories, or the package is not installed | Check `/usr/share/omarchy-onnx-models/` for the file. omarchy-broadcast also searches its own model directories, in the order described in its ONNX setup guide |

## Build the packages from a clone

Use this to build the packages from the repository instead of the AUR. `makepkg` needs the release `v<pkgver>` to be published.

```bash
git clone https://github.com/rsd/omarchy-onnx-models.git
cd omarchy-onnx-models/packaging/arch
makepkg                                                  # downloads and checks the sources
sudo pacman -U omarchy-onnx-model-modnet-*.pkg.tar.zst   # one package, or several
```

`pkgver` is the release tag without its `v`, so `1.0.0` builds from `v1.0.0`. The sources are the release's model files and the licence and notice files of the release tag, each pinned by SHA-256. The downloads and the packages stay in `packaging/arch/`, which its `.gitignore` excludes from git.

## Rebuild the files (optional)

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

Why the MediaPipe file needs a reference, and how the build proves equivalence: [docs/release.md](docs/release.md#reproducibility). The release procedure: [docs/release.md](docs/release.md).
