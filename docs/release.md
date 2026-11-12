# Making a release

The model files are published as the assets of a GitHub release of this repository. Releases are made by hand, by a maintainer; no workflow uploads anything.

## Tags and versions

- Tags are `v<MAJOR>.<MINOR>.<PATCH>`; the first release is `v1.0.0`.
- **The assets of a published tag are never replaced.** Consumers pin each file's SHA-256, so a changed file under an existing URL breaks every one of them. Whenever any release file changes (a model, `NOTICE`, the licence text, `MANIFEST.toml`), publish a new tag.
- `MAJOR`: a file is removed or renamed, or a model's inputs or outputs change. `MINOR`: a model is added. `PATCH`: anything else that changes a file's bytes (a re-conversion with other tool versions, a corrected notice or manifest).
- The checksums in `models.toml`, `README.md` and `docs/models.md` describe the files of the latest release; `scripts/test.sh` checks that they agree with each other.

## 1. Build and check

From a clean checkout of the commit to release (the manifest records the commit; a tree with uncommitted changes or untracked files, ignored files aside, is recorded as `<commit>-modified`):

```bash
git status --short                 # nothing at all: no change, no untracked file
scripts/test.sh
mkdir -p ../references             # outside the repository
gh release download <latest tag> --repo <owner>/omarchy-onnx-models \
    --pattern selfie_segmentation_landscape.onnx --dir ../references
scripts/build-models.sh --reference-dir ../references
(cd dist && sha256sum -c SHA256SUMS)
grep '^source_revision' dist/MANIFEST.toml; git rev-parse HEAD
```

Before publishing, check that `source_revision` in `dist/MANIFEST.toml` is exactly the commit to release, `git rev-parse HEAD`: 40 hex digits, without `-modified` and not `unknown`. Otherwise the files were not built from that commit; commit or remove what `git status` shows and build again.

The reference download is the published MediaPipe file, which the build ships after checking it (see [Reproducibility](#reproducibility)). For the first release, the reference is the evaluation's conversion whose SHA-256 is in `models.toml`; pass its directory the same way.

`scripts/build-models.sh` fails, and leaves `dist/` as it was, when a release file's SHA-256 differs from `models.toml`, when a reference file is missing or is not the pinned file, and when a fresh conversion is not equivalent to its reference. Do not release such a build: find the cause first (`build/build-models.log`; the tool versions in `requirements/`). If the new file is intended, update `models.toml`, `README.md` and `docs/models.md` in a commit of their own, then build again and release under a new tag.

**Slow upstream host.** `paddleseg.bj.bcebos.com`, the host of the PP-HumanSeg originals, has served them at a few KB/s (about 6 KB/s, for 39 MB of archives). When it does, download the two archives once, by any means, into a directory of their upstream file names, and pass it with `--input-dir <dir>`: the build still checks each one against the `input_sha256` of `models.toml` before using it, and records a local copy in `MANIFEST.toml` as `a local copy (--input-dir), SHA-256 checked`, without its path. Files missing from the directory are downloaded as usual.

`dist/` then holds the release files, all at its top level, and the marker file `.omarchy-onnx-models-dist`. The build writes the marker so that it can recognise the directory next time: it replaces the contents of `dist/` (or of `--dist <dir>`) only when the directory is absent, empty, or carries the marker, and refuses any other directory without touching it. The marker is not a release file: it is in neither `SHA256SUMS` nor `MANIFEST.toml`, and `dist/*` in the commands below does not match it.

| File | Contents |
|---|---|
| `selfie_segmentation_landscape.onnx`, `pp_humansegv2_mobile_192x192.onnx`, `pp_humansegv2_lite_192x192.onnx`, `modnet_photographic.onnx` | the models |
| `LICENSE-Apache-2.0` | the licence of the models |
| `NOTICE` | the attribution and modification notice of each model |
| `MANIFEST.toml` | per file: size, SHA-256, upstream sources and their checksums, licence, how it was made, the tool versions |
| `SHA256SUMS` | the SHA-256 of every other file, in `sha256sum` format |

## Tool pins and lock files

Each conversion environment is pinned twice: `requirements/<name>.txt` lists every package with its exact version, and `requirements/<name>.lock` is the same set with the SHA-256 of every distribution PyPI holds for those versions. The build installs from the lock with `uv pip sync --require-hashes`, so a wheel with any other hash is refused, and then checks that the environment holds exactly the packages of the `.txt`. uv runs with `--no-config` (no `uv.toml` or `pyproject.toml` settings) and `--default-index https://pypi.org/simple`, with `UV_INDEX_URL`, `UV_EXTRA_INDEX_URL`, `UV_INDEX`, `UV_DEFAULT_INDEX`, `UV_FIND_LINKS`, `PIP_INDEX_URL` and the like removed from its environment, so no other index can be brought in. A kept environment (`--keep-venvs`) is reused only when its Python is the pinned version; otherwise it is made anew.

To change a pin: edit `requirements/<name>.txt` (every package of the environment, exact versions), then regenerate the locks and run the tests:

```bash
scripts/lock-requirements.sh       # uv pip compile --generate-hashes, per environment
scripts/test.sh                    # the locks name exactly the packages of the .txt files
```

`scripts/lock-requirements.sh` resolves each environment for its own Python version (`3.12.16` for `tflite` and `verify`, `3.10.22` for `paddle`, the versions in `scripts/lib/common.sh`) and for x86_64 Linux, against PyPI only, with the same `--no-config` and index rules as the build. Commit the `.txt` and the `.lock` together. A changed pin can change a release file's bytes: build, compare with `models.toml`, and handle a difference as described in step 1.

## Reproducibility

The build makes every release file from its upstream original, with every tool pinned exactly. Three files are **byte-reproducible**: every build makes the same bytes, and the build fails when their SHA-256 differs from `models.toml`.

| File | How the build checks it |
|---|---|
| `pp_humansegv2_mobile_192x192.onnx`, `pp_humansegv2_lite_192x192.onnx` | byte-identical: the fresh conversion's SHA-256 must be the one in `models.toml` |
| `modnet_photographic.onnx` | byte-identical: the upstream file, copied unchanged |
| `selfie_segmentation_landscape.onnx` | verified equivalent: the release file is a supplied reference; a fresh conversion must be equivalent to it |

**Why MediaPipe is not byte-reproducible.** `tf2onnx` 1.17.0 gives the constants it folds names with run-dependent numbers (`const_fold_opt__N`, `new_shape__N`) and, in some runs, keeps one more `Reshape` to the same shape; no two runs give the same bytes, and `PYTHONHASHSEED` does not change that. The weights, the operators and the outputs do not change. `models.toml` marks such a model `reproducible = false` and gives its `equivalence_tolerance`.

**How a reference file is checked.** For a model with `reproducible = false`, `scripts/build-models.sh --reference-dir <dir>` takes `<dir>/<release file name>` and:

1. checks its SHA-256 against `models.toml` before anything else; a mismatch stops the build;
2. converts the original afresh, by the same pinned recipe;
3. checks both files (`convert/verify_model.py`: `onnx.checker`, the opset against `opset` in `models.toml`, the input and output names and shapes, a smoke inference) and summarises each (`--summary`);
4. compares the two summaries (`scripts/lib/equivalence.py`). They must have the same IR version; the same opset imports; the same graph inputs and outputs (names, types, shapes); the same initializer tensors as a multiset, compared exactly (type, shape and the SHA-256 of the values; names are not compared); and the same multiset of nodes (domain, operator and attributes), leaving out only no-op nodes: a `Reshape` whose data input and output have the same fully static shape and type after ONNX shape inference, which returns its input unchanged. Their outputs on eight deterministic inputs (the smoke input, two synthetic head-and-shoulders pictures that make the model return a full-range matte, two ramps and three constants), run on the CPU with one thread, must be finite and differ by at most the tolerance: 1e-6 for MediaPipe. The outputs lie in `[0, 1]`, where 1e-6 is about eight float32 steps at 1.0: it allows a different summation order and nothing else, while a changed weight or operator moves them by orders of magnitude more;
5. writes the reference file, not the fresh one, to `dist/`. `MANIFEST.toml` records, for that file, `provenance = "reference conversion, verified equivalent"` and a `[file.equivalence]` table: the fresh file's SHA-256 and size, the counts compared, the no-op rule and how many nodes it left out on each side, the probes, the largest difference and the tolerance.

Without `--reference-dir` (or without the file in it) the build stops before any work and says so. With `--accept-new-checksums` and no reference it builds the fresh file instead, reports its SHA-256 as a mismatch and writes it to `dist/`; it never rewrites `models.toml`. Such a file is not the published one: release it only as a deliberate change (a new checksum in `models.toml`, the docs and a new tag).

**Where the reference comes from.** For a rebuild, the reference is the asset of the latest published release (`https://github.com/<owner>/omarchy-onnx-models/releases/download/<tag>/selfie_segmentation_landscape.onnx`, or `gh release download` as above), whose SHA-256 is the one `models.toml` pins. A release never replaces a published asset: a rebuild of an unchanged recipe ships the same reference bytes, and a changed MediaPipe file is a new checksum and a new tag, never a new file under an old one.

## 2. Tag and publish

Tag the commit that was built, push the tag, and create the release with every file of `dist/` as an asset. With the GitHub CLI:

```bash
tag=v1.0.0
git tag -a "$tag" -m "omarchy-onnx-models $tag"
git push origin "$tag"
gh release create "$tag" dist/* --title "omarchy-onnx-models $tag" --notes-file notes.md
```

`notes.md` is written for the release (keep it outside the repository, or delete it after): what changed since the previous tag, and the contents of `SHA256SUMS`. A starting point:

```bash
{
    echo "ONNX files of four Apache-2.0 person-segmentation models. Licence: LICENSE-Apache-2.0; attribution: NOTICE; provenance: MANIFEST.toml."
    echo
    echo '```'
    cat dist/SHA256SUMS
    echo '```'
} >notes.md
```

Without the CLI, in the web interface: **Releases → Draft a new release**, choose the tag (or create it on the commit that was built), set the title, paste the notes, drag every file of `dist/` into the assets area, and **Publish release**.

After publishing, download the assets once and check them, from an empty directory:

```bash
gh release download "$tag" --repo <owner>/omarchy-onnx-models
sha256sum -c SHA256SUMS
```

## Download URLs

Each asset is at:

```
https://github.com/<owner>/omarchy-onnx-models/releases/download/<tag>/<file>
```

for example `https://github.com/<owner>/omarchy-onnx-models/releases/download/v1.0.0/modnet_photographic.onnx`. `<owner>` is the GitHub account or organisation that hosts the repository.

## Consuming the files from a PKGBUILD

List each file in `source=()` and its SHA-256, from the release's `SHA256SUMS`, in `sha256sums=()`, in the same order. Install the licence and the notice with the files:

```bash
_models_tag=v1.0.0
_models_url=https://github.com/<owner>/omarchy-onnx-models/releases/download/$_models_tag
source=(
    "$_models_url/selfie_segmentation_landscape.onnx"
    "$_models_url/pp_humansegv2_mobile_192x192.onnx"
    "$_models_url/pp_humansegv2_lite_192x192.onnx"
    "$_models_url/modnet_photographic.onnx"
    "$_models_url/LICENSE-Apache-2.0"
    "$_models_url/NOTICE"
)
sha256sums=(
    'fa02222275c455638fa1190493b659d25ad31e86f1b6459f17bd501f02cbe43d'
    '2bca11ec1f2a662146147d97523d613f5ef4ebf2a89803a95a0cbabfe2bd70a9'
    'ca96b4436f1ce6a76059e8902e20a9617f6829fb11f6c6c9e876563e6352e6b4'
    '07c308cf0fc7e6e8b2065a12ed7fc07e1de8febb7dc7839d7b7f15dd66584df9'
    '<sha256 of LICENSE-Apache-2.0 from SHA256SUMS>'
    '<sha256 of NOTICE from SHA256SUMS>'
)

package() {
    install -Dm644 -t "$pkgdir/usr/share/<package>/models" ./*.onnx
    install -Dm644 -t "$pkgdir/usr/share/licenses/$pkgname" LICENSE-Apache-2.0 NOTICE
}
```

`makepkg` downloads each file and refuses any whose checksum differs. To bring a PKGBUILD to a new tag, change the tag and copy the lines of the new `SHA256SUMS`. Several sources with one file name (two models' `NOTICE`, for instance) need distinct names: `"<name>::<url>"`.
