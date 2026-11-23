# omarchy-onnx-models

Four open person-segmentation models as ONNX files, as Arch packages and as plain downloads.

These are the model files. To run them on your hardware, see [omarchy-onnxruntime](https://github.com/rsd/omarchy-onnxruntime).

If you installed the omarchy-broadcast ONNX module on Arch or Omarchy, you already have its model. Nothing to do.

## Models

| Package | Size | Who it is for |
|---|---|---|
| `omarchy-onnx-model-mediapipe-landscape` | 0.4 MB | Start here. omarchy-broadcast uses it unless you choose another, and its ONNX module installs it for you. The smallest and lightest. |
| `omarchy-onnx-model-pphumanseg-v2-lite` | 12 MB | You want a second option that is still light. |
| `omarchy-onnx-model-pphumanseg-v2-mobile` | 30 MB | The larger PP-HumanSeg variant. Upstream reports it as more accurate than lite, for more compute. |
| `omarchy-onnx-model-modnet` | 26 MB | A matting model: soft edges around hair and fine detail instead of a hard mask. The heaviest to run. |

The packages install, in order, `selfie_segmentation_landscape.onnx`, `pp_humansegv2_lite_192x192.onnx`, `pp_humansegv2_mobile_192x192.onnx` and `modnet_photographic.onnx`.

## Install

### Arch or Omarchy

```bash
yay -S omarchy-onnx-model-modnet
```

Use any package name from the table. Any one package downloads all four files (about 69 MB), because the four share one recipe.

### Any other distribution

```bash
dir=${XDG_DATA_HOME:-$HOME/.local/share}/omarchy-broadcast/models/onnx
base=https://github.com/rsd/omarchy-onnx-models/releases/latest/download
mkdir -p "$dir" && cd "$dir"
curl -fLO "$base/selfie_segmentation_landscape.onnx" -O "$base/LICENSE-Apache-2.0" -O "$base/NOTICE" -O "$base/SHA256SUMS"
sha256sum --ignore-missing -c SHA256SUMS
```

That directory is where omarchy-broadcast looks for a per-user model; its [ONNX setup guide](https://github.com/rsd/omarchy-broadcast/blob/main/docs/setup/onnx.md) covers the rest. This downloads the model omarchy-broadcast uses unless you choose another; for another model, replace `selfie_segmentation_landscape.onnx` with its file name from the list above.

If a line says `FAILED`, download that file again. If it persists, [open an issue](https://github.com/rsd/omarchy-onnx-models/issues).

## Licence

- This repository's content is MIT OR Apache-2.0, at your option: [LICENSE-MIT](LICENSE-MIT), [LICENSE-APACHE](LICENSE-APACHE).
- The model files are Apache-2.0, from their upstream projects ([NOTICE](NOTICE)).
- When you redistribute a model file, ship `LICENSE-Apache-2.0` and `NOTICE` with it.
- The training-data terms of PP-HumanSeg and MODNet are not confirmed: read the training-data notes in [docs/models.md](docs/models.md).

## More

- [docs/models.md](docs/models.md): inputs, outputs and how each file was made.
- [docs/maintainers.md](docs/maintainers.md): the repository layout, the tests and the rebuild.
- [docs/release.md](docs/release.md): the release procedure.
