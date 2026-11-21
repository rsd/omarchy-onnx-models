# The models

This page describes the four person-segmentation models, each under the Apache License, Version 2.0. For each model it gives where it comes from, the evidence for its licence, what is known about its training data, how the ONNX file is made and how to feed it. Read it before you rely on a model: the training-data terms of PP-HumanSeg and MODNet are not confirmed.

The same facts, in machine-readable form, are in [`models.toml`](../models.toml) and in each release's `MANIFEST.toml`. The licence texts and notices are in [`licenses/<id>/LICENSE`](../licenses) and [`licenses/<id>/NOTICE`](../licenses), collected in [`NOTICE`](../NOTICE). This page reports what the upstream projects publish; it is not legal advice.

## Summary

| Id | File | Upstream original | Original SHA-256 | Release file SHA-256 |
|---|---|---|---|---|
| `mediapipe-landscape` | `selfie_segmentation_landscape.onnx` | `selfie_segmentation_landscape.tflite` | `a77d03f4659b9f6b6c1f5106947bf40e99d7655094b6527f214ea7d451106edd` | `fa02222275c455638fa1190493b659d25ad31e86f1b6459f17bd501f02cbe43d` |
| `pphumanseg-v2-mobile` | `pp_humansegv2_mobile_192x192.onnx` | `human_pp_humansegv2_mobile_192x192_inference_model_with_softmax.zip` | `4e1ef6f06bbf6b054bc33664a0a71df622ee397a0f3e78a22ef7f96cf82a771b` | `2bca11ec1f2a662146147d97523d613f5ef4ebf2a89803a95a0cbabfe2bd70a9` |
| `pphumanseg-v2-lite` | `pp_humansegv2_lite_192x192.onnx` | `human_pp_humansegv2_lite_192x192_inference_model_with_softmax.zip` | `9d86bc9c86c282cc2e92eaa089b96e18d30776c6ca745be18e6251a4e2a00110` | `ca96b4436f1ce6a76059e8902e20a9617f6829fb11f6c6c9e876563e6352e6b4` |
| `modnet` | `modnet_photographic.onnx` | the upstream ONNX export | `07c308cf0fc7e6e8b2065a12ed7fc07e1de8febb7dc7839d7b7f15dd66584df9` | `07c308cf0fc7e6e8b2065a12ed7fc07e1de8febb7dc7839d7b7f15dd66584df9` (unmodified) |

| Id | Input | Output |
|---|---|---|
| `mediapipe-landscape` | `input_1`, `[1, 144, 256, 3]` float32, NHWC | `segment_back`, `[1, 144, 256, 1]`, alpha in `[0, 1]` |
| `pphumanseg-v2-mobile` | `x`, `[1, 3, 192, 192]` float32, NCHW | `save_infer_model/scale_0.tmp_0`, `[1, 2, 192, 192]` (declared `[1, 2, ?, ?]`), softmax; the matte is channel 1 |
| `pphumanseg-v2-lite` | `x`, `[1, 3, 192, 192]` float32, NCHW | `save_infer_model/scale_0.tmp_0`, `[1, 2, 192, 192]` (declared `[1, 2, ?, ?]`), softmax; the matte is channel 1 |
| `modnet` | `input`, `[1, 3, H, W]` float32, NCHW; batch, `H` and `W` dynamic | `output`, `[1, 1, H, W]`, alpha in `[0, 1]` |

## MediaPipe Selfie Segmentation (landscape, 144x256)

| | |
|---|---|
| Id, file | `mediapipe-landscape`, `selfie_segmentation_landscape.onnx` |
| Upstream | Google, MediaPipe: <https://github.com/google-ai-edge/mediapipe> |
| Original | <https://storage.googleapis.com/mediapipe-assets/selfie_segmentation_landscape.tflite>, SHA-256 `a77d03f4659b9f6b6c1f5106947bf40e99d7655094b6527f214ea7d451106edd` |
| Licence | Apache-2.0. Code: <https://github.com/google-ai-edge/mediapipe/blob/master/LICENSE>. Weights: the model card states "LICENSED UNDER Apache License, Version 2.0" |
| Model card | <https://storage.googleapis.com/mediapipe-assets/Model%20Card%20MediaPipe%20Selfie%20Segmentation.pdf> |
| Training data | Described in the model card (Google's own data set); no further terms stated |

**Conversion (a modified file, Apache-2.0 §4(b)).** `tf2onnx` converts the TensorFlow Lite file at opset 17. The file's `HardSwish` operators need opset 14 or newer. `tf2onnx` leaves MediaPipe's custom operator `Convolution2DTransposeBias` as an unknown node. [`convert/fix_tconv.py`](../convert/fix_tconv.py) replaces each such node with standard ONNX nodes (NHWC to NCHW `Transpose`, a `ConvTranspose` with stride 2 and the same weights and bias, back to NHWC) and runs `onnx.checker`. The weights are unchanged. The result keeps the TFLite layout (NHWC). It gives the same matte as the community conversion `onnx-community/mediapipe_selfie_segmentation_landscape` (NCHW), within 4e-5.

**Reproducibility.** This conversion is not byte-reproducible. `tf2onnx` names its folded constants differently on every run, and sometimes keeps one more `Reshape` to the same shape. The weights, the operators and the outputs stay the same. The release file is therefore a reference conversion, SHA-256 `fa02222275c455638fa1190493b659d25ad31e86f1b6459f17bd501f02cbe43d`, made by this recipe. Every build checks the reference against that checksum and converts the original afresh. It proves the two equivalent before it ships the reference:

- the same initializers, exactly;
- the same operators, no-op `Reshape`s aside;
- the same inputs, outputs and opsets;
- outputs within 1e-6 on eight deterministic inputs.

The details are in [`docs/release.md`](release.md#reproducibility). Each release's `MANIFEST.toml` records the result. The other three files are byte-reproducible.

**Preprocessing.** RGB, values in `[0, 1]` (`v / 255`), NHWC, the frame resized to 144x256 (height x width). The output is the person's alpha.

## PP-HumanSeg v2 (mobile and lite, 192x192)

| | |
|---|---|
| Ids, files | `pphumanseg-v2-mobile`, `pp_humansegv2_mobile_192x192.onnx`; `pphumanseg-v2-lite`, `pp_humansegv2_lite_192x192.onnx` |
| Upstream | Baidu, PaddleSeg, PP-HumanSeg: <https://github.com/PaddlePaddle/PaddleSeg/tree/release/2.9/contrib/PP-HumanSeg> (the originals are listed in its `README.md`, release 2.9) |
| Originals | <https://paddleseg.bj.bcebos.com/dygraph/pp_humanseg_v2/human_pp_humansegv2_mobile_192x192_inference_model_with_softmax.zip>, SHA-256 `4e1ef6f06bbf6b054bc33664a0a71df622ee397a0f3e78a22ef7f96cf82a771b`; <https://paddleseg.bj.bcebos.com/dygraph/pp_humanseg_v2/human_pp_humansegv2_lite_192x192_inference_model_with_softmax.zip>, SHA-256 `9d86bc9c86c282cc2e92eaa089b96e18d30776c6ca745be18e6251a4e2a00110` |
| Licence | Apache-2.0: <https://github.com/PaddlePaddle/PaddleSeg/blob/release/2.9/LICENSE>. The weights are released inside PaddleSeg, with no separate weights licence |
| Model card | The PP-HumanSeg README: <https://github.com/PaddlePaddle/PaddleSeg/blob/release/2.9/contrib/PP-HumanSeg/README.md> |
| Training data | **UNCONFIRMED.** The models are trained on PP-HumanSeg14K among other data. PP-HumanSeg14K is available only on request from Baidu (`paddleseg@baidu.com`), and no licence for it is stated publicly. Whether its terms reach the weights has not been confirmed |

**Conversion (modified files, Apache-2.0 §4(b)).** The Paddle inference models have a dynamic input shape. [`convert/pp_static.py`](../convert/pp_static.py) re-saves each with the input fixed at `1x3x192x192`. `paddle2onnx` needs this to export the pooling with a fixed kernel. Then `paddle2onnx` exports the model at opset 13. For `lite`, `paddle2onnx` raises the opset to 14 itself, which its `hard_swish` operator needs. When the export still holds an `AveragePool` whose kernel is `[-1, -1]` (an adaptive pooling it could not resolve), [`convert/pp_fix_pool.py`](../convert/pp_fix_pool.py) sets its kernel and stride from the fixed shape. The build detects this per file and records it in the run log and in `MANIFEST.toml` (`conversion_steps`). With the pinned versions neither file needs it, because the static input shape already lets `paddle2onnx` resolve the pooling. The weights are unchanged.

**Preprocessing.** RGB, `(v / 255 - 0.5) / 0.5` (values in `[-1, 1]`), NCHW, the frame squashed to 192x192 (the aspect ratio is not kept). The output is a softmax over background (channel 0) and person (channel 1); the matte is channel 1. The file declares the output's height and width as dynamic; with the static input they are 192.

## MODNet (photographic)

| | |
|---|---|
| Id, file | `modnet`, `modnet_photographic.onnx` |
| Upstream | Zhanghan Ke et al., MODNet: Trimap-Free Portrait Matting in Real Time: <https://github.com/ZHKKKe/MODNet> |
| Original | The ONNX version of the official image matting model, linked from <https://github.com/ZHKKKe/MODNet/blob/master/onnx/README.md> (Google Drive file `1cgycTQlYXpTh26gB9FTnthE7AvruV8hd`); a byte-identical copy is `onnx/model.onnx` of <https://huggingface.co/Xenova/modnet>, which the build uses as a mirror, pinned to commit `fa2fa546052fba4c08921230a26cc69a333fca12`. SHA-256 `07c308cf0fc7e6e8b2065a12ed7fc07e1de8febb7dc7839d7b7f15dd66584df9` |
| Licence | Apache-2.0: the README states "The code, models, and demos in this repository … are released under the Apache License 2.0" |
| Model card | The repository's README and `onnx/README.md`; the paper describes the training |
| Training data | **UNCONFIRMED.** Not named in the README (the paper describes it); its terms are not confirmed |

**Conversion.** None: the release file is the upstream ONNX export, unmodified.

**Preprocessing.** RGB, values in `[-1, 1]` (`v / 127.5 - 1`), NCHW, batch 1. Scale the frame so that its short side is 288 and round both sides to a multiple of 32 (288x512 for 16:9). The output is the alpha matte at the input size.

## Verification

Every build checks each release file: `onnx.checker` (full check), the input and output names and shapes above (the named dimensions must be dynamic), and a CPU inference with ONNX Runtime on a deterministic synthetic input in the model's value range (288x512 for MODNet), whose output must have the expected shape, be finite and lie in `[0, 1]`. This checks that each file loads and runs; it does not measure segmentation quality.

The byte-reproducible files must also have the SHA-256 of the table above. For MediaPipe, whose conversion is not byte-reproducible, the build checks the supplied reference file against its SHA-256 and a fresh conversion for equivalence with it, as [`docs/release.md`](release.md#reproducibility) describes.
