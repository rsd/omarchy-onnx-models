# Install the models

Put the ONNX model files on your machine. ONNX (Open Neural Network Exchange) is a standard file format for trained models. On Arch Linux and Omarchy, install one package per model from the AUR (the Arch User Repository). On any other Linux distribution, download the files and check them.

## Before you start

- About 70 MB of free disk for all four models.
- A program that runs ONNX models, and ONNX Runtime for it. The omarchy-broadcast ONNX cut-out module needs ONNX Runtime 1.29 or newer: see [omarchy-onnxruntime](https://github.com/rsd/omarchy-onnxruntime) and its [ONNX setup guide](https://github.com/rsd/omarchy-broadcast/blob/main/docs/setup/onnx.md).
- For the packages: Omarchy or Arch Linux, an AUR helper such as `yay`, and `sudo`. The four packages share one recipe, so building any one of them downloads the files of all four models.
- For the files alone, on any distribution: `curl` and `sha256sum`.

## Install on Arch or Omarchy

1. Install the default model, `omarchy-onnx-model-mediapipe-landscape`.

   ```bash
   yay -S omarchy-onnx-model-mediapipe-landscape
   ```

   The package downloads its file from the `v1.0.0` release and refuses a file whose SHA-256 differs from the one in the recipe. You do not need this step when you install the omarchy-broadcast ONNX module: that package depends on the default model.

2. Optional: install more models. Each package is independent, so install any combination.

   ```bash
   yay -S omarchy-onnx-model-pphumanseg-v2-mobile omarchy-onnx-model-pphumanseg-v2-lite omarchy-onnx-model-modnet
   ```

| Package | Installs | Made from |
|---|---|---|
| `omarchy-onnx-model-mediapipe-landscape` (default) | `selfie_segmentation_landscape.onnx` | MediaPipe Selfie Segmentation (landscape) |
| `omarchy-onnx-model-pphumanseg-v2-mobile` | `pp_humansegv2_mobile_192x192.onnx` | PP-HumanSeg v2 mobile |
| `omarchy-onnx-model-pphumanseg-v2-lite` | `pp_humansegv2_lite_192x192.onnx` | PP-HumanSeg v2 lite |
| `omarchy-onnx-model-modnet` | `modnet_photographic.onnx` | MODNet |

[docs/models.md](docs/models.md) describes each model, and its training-data notes say what is not confirmed.

## Use the files on another distribution

The `.onnx` files are plain files. Any Linux distribution can use them, with any program that runs ONNX models. This route downloads the files of a release, checks them and puts them where the omarchy-broadcast module looks.

1. Download the files into a directory. This example uses the per-user model directory of the omarchy-broadcast module and the default model. For another model, replace the file name with the one in the table above. Every asset of a release is at `https://github.com/rsd/omarchy-onnx-models/releases/download/<tag>/<file>`.

   ```bash
   tag=v1.0.0
   base=https://github.com/rsd/omarchy-onnx-models/releases/download/$tag
   dir=${XDG_DATA_HOME:-~/.local/share}/omarchy-broadcast/models/onnx
   mkdir -p "$dir"
   cd "$dir"
   for f in selfie_segmentation_landscape.onnx LICENSE-Apache-2.0 NOTICE SHA256SUMS; do
       curl -fLO "$base/$f"
   done
   ```

   `LICENSE-Apache-2.0` and `NOTICE` are the licence text and the attribution of the models. Keep them with the files.

2. Check the files against the release's checksums.

   ```bash
   sha256sum --ignore-missing -c SHA256SUMS
   ```

   Each file you downloaded prints `<file>: OK`. Files you did not download are skipped. If a line says `FAILED`, delete the file and download it again.

3. Make sure the program finds the files. omarchy-broadcast searches these directories and uses the first that has the file:

   1. `model_dir` in `[module."br.com.dias.onnx-cutout"]` of `config.toml`;
   2. `$OBC_ONNX_MODEL_DIR`;
   3. `$XDG_DATA_HOME/omarchy-broadcast/models/onnx/`, by default `~/.local/share/omarchy-broadcast/models/onnx/` (step 1 uses it);
   4. `/usr/share/omarchy-onnx-models/`, where the Arch packages install (use it for a system-wide install, as root);
   5. `/usr/share/omarchy-broadcast/models/onnx/`.

   The [ONNX setup guide](https://github.com/rsd/omarchy-broadcast/blob/main/docs/setup/onnx.md) of omarchy-broadcast describes the search and the module's checks. Another program reads the files from wherever you point it.

## Check that it works

On Arch, list the files a package installed:

```bash
pacman -Ql omarchy-onnx-model-mediapipe-landscape
```

The list includes the model file, the licence and the notice:

```text
omarchy-onnx-model-mediapipe-landscape /usr/share/licenses/omarchy-onnx-model-mediapipe-landscape/LICENSE
omarchy-onnx-model-mediapipe-landscape /usr/share/licenses/omarchy-onnx-model-mediapipe-landscape/NOTICE
omarchy-onnx-model-mediapipe-landscape /usr/share/omarchy-onnx-models/selfie_segmentation_landscape.onnx
```

Check the installed files against the release's checksums. Use the tag that matches the package version: the package version `1.0.0` is the tag `v1.0.0`. Read the version with:

```bash
pacman -Q omarchy-onnx-model-mediapipe-landscape
```

Then check the files:

```bash
curl -sL https://github.com/rsd/omarchy-onnx-models/releases/download/v1.0.0/SHA256SUMS \
    | (cd /usr/share/omarchy-onnx-models && sha256sum --ignore-missing -c)
```

Each installed model prints `<file>: OK`. Files you did not install are skipped:

```text
selfie_segmentation_landscape.onnx: OK
```

On another distribution, the check is step 2 of the route above. With omarchy-broadcast, restart the daemon and list its modules. The ONNX module shows its stage `background`, or the reason it cannot run:

```bash
systemctl --user restart omarchy-broadcastd
omarchy-broadcast modules
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| The build stops with a failed checksum | A downloaded file differs from the SHA-256 in the PKGBUILD, for example a truncated or replaced download | Clear your AUR helper's cache and build again. A published asset is never replaced, so a mismatch that persists is an error to report |
| `sha256sum` prints `FAILED` for a file you downloaded | The download is truncated, or it is from another tag than the `SHA256SUMS` | Delete the file and download it again from the same tag as `SHA256SUMS`. A published asset is never replaced, so a mismatch that persists is an error to report |
| A program does not find the model | It searches other directories, or the file is not there | Check that the file is in a directory the program searches, such as `/usr/share/omarchy-onnx-models/` for the packages. omarchy-broadcast also searches its own model directories, in the order of its [ONNX setup guide](https://github.com/rsd/omarchy-broadcast/blob/main/docs/setup/onnx.md) |

## Uninstall

Remove each model package you installed:

```bash
sudo pacman -R omarchy-onnx-model-<id>      # for each model package you installed
```

If the omarchy-broadcast ONNX module is installed, it depends on the default model. Remove the module first, or remove it with `pacman -Rs`, which also removes the dependencies nothing else needs, the default model among them. Use `omarchy-broadcast-onnx-bin` in place of `omarchy-broadcast-onnx-git` for the prebuilt module:

```bash
sudo pacman -Rs omarchy-broadcast-onnx-git
```

Files you downloaded by hand are plain files: delete them.

## Details

### What a package contains

All four packages come from one AUR base, `omarchy-onnx-models`, and are architecture independent (`arch=('any')`). [`packaging/arch/PKGBUILD`](packaging/arch/PKGBUILD) is one split recipe for the four packages.

- Each package installs its model into `/usr/share/omarchy-onnx-models/`, a directory that belongs to no one program.
- Each installs its licence (`LICENSE`) and notice (`NOTICE`) into `/usr/share/licenses/<package>/`.
- The sources are the release's model files and the licence and notice files of the release tag, each pinned by SHA-256. Nothing is taken from a checkout.
- `pkgver` is the release tag without its `v`: `1.0.0` builds from `v1.0.0`. The packages follow each release (step 3 of [docs/release.md](docs/release.md#3-update-the-arch-packages)).
- [`scripts/srcinfo.sh`](scripts/srcinfo.sh) prepares the AUR recipe from this one.

### Build the packages from a clone

Use this to build the packages from the repository instead of the AUR. `makepkg` needs the release `v<pkgver>` to be published.

```bash
git clone https://github.com/rsd/omarchy-onnx-models.git
cd omarchy-onnx-models/packaging/arch
makepkg                                                  # downloads and checks the sources
sudo pacman -U omarchy-onnx-model-modnet-*.pkg.tar.zst   # one package, or several
```

The downloads and the packages stay in `packaging/arch/`, which its `.gitignore` excludes from git. The same version rule applies: `1.0.0` builds from `v1.0.0`.

### Rebuild the files

To convert the files again from the upstream originals, see [Rebuild the files](docs/maintainers.md#rebuild-the-files). You do not need this to use the models.
