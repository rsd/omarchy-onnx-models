# omarchy-onnx-models

Four open person-segmentation models as ONNX files, as Arch packages and as plain downloads.

These are the model files. To run them on your hardware, see [omarchy-onnxruntime](https://github.com/rsd/omarchy-onnxruntime).

If you installed the omarchy-broadcast ONNX module on Arch or Omarchy, you already have the first model below. Install another only to switch to it.

## Models

All four do the same job: they take a camera frame and return a mask of the person, so a program can blur or replace the background. They differ in how fine the mask is and in what it costs to run.

| Package | What it is for | Size |
|---|---|---|
| `omarchy-onnx-model-mediapipe-landscape` | **Fast.** Google's MediaPipe Selfie Segmentation, with a 256×144 mask. omarchy-broadcast uses this one out of the box. | 0.4 MB |
| `omarchy-onnx-model-pphumanseg-v2-lite` | **Lite.** The small variant of Baidu's PP-HumanSeg v2, with a 192×192 mask. | 12 MB |
| `omarchy-onnx-model-pphumanseg-v2-mobile` | **Quality.** The large variant of PP-HumanSeg v2, with a 192×192 mask. Upstream scores it 93.1% against 92.5% for lite (mIoU, a measure of mask accuracy). | 30 MB |
| `omarchy-onnx-model-modnet` | **Sharp hair, on a GPU.** MODNet portrait matting: edges are partly transparent instead of cut hard, on a 512×288 mask for a 16:9 camera. | 26 MB |

The words in bold are the labels omarchy-broadcast shows for each model in its "Model" setting.

## Install

### Arch or Omarchy

```bash
yay -S omarchy-onnx-model-modnet
```

Use any package name from the table. Any one package downloads all four files (about 69 MB), because the four share one recipe.

Installing a model does not switch to it. In omarchy-broadcast, pick it in the "Model" setting: see [Choose the model and the engine](https://github.com/rsd/omarchy-broadcast/blob/main/docs/setup/onnx.md#choose-the-model-and-the-engine).

### Any other distribution

```bash
dir=${XDG_DATA_HOME:-$HOME/.local/share}/omarchy-broadcast/models/onnx
base=https://github.com/rsd/omarchy-onnx-models/releases/latest/download
mkdir -p "$dir" && cd "$dir"
curl -fLO "$base/selfie_segmentation_landscape.onnx" -O "$base/LICENSE-Apache-2.0" -O "$base/NOTICE" -O "$base/SHA256SUMS"
sha256sum --ignore-missing -c SHA256SUMS
```

This downloads the MediaPipe model into the directory where omarchy-broadcast looks for a per-user model. For another model, replace `selfie_segmentation_landscape.onnx` with `pp_humansegv2_lite_192x192.onnx`, `pp_humansegv2_mobile_192x192.onnx` or `modnet_photographic.onnx`. The rest is in omarchy-broadcast's [ONNX setup guide](https://github.com/rsd/omarchy-broadcast/blob/main/docs/setup/onnx.md).

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
