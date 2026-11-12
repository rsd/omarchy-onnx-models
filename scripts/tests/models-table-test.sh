#!/usr/bin/env bash
# shellcheck disable=SC2016 # Python and sh -c programs in single quotes, on purpose
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Tests of the model table (models.toml) and its reader scripts/lib/models.py:
# the repository's own table must be consistent with the licence files, the
# NOTICE, README.md and docs/models.md; and the checks must catch each kind
# of defect, on altered copies of the repository's files under mktemp.
# System python3 (3.11 or newer), standard library only, no network.
# Usage: scripts/tests/models-table-test.sh. Exits non-zero on any failure.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
top=$(cd "$here/../.." && pwd)
models_py=$top/scripts/lib/models.py

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fails=0 count=0
ok() { count=$((count + 1)); echo "ok   $1"; }
fail() { count=$((count + 1)); echo "FAIL $1"; fails=$((fails + 1)); }

py() { python3 -I "$models_py" "$@"; }

echo "== the repository's table"
if out=$(py --models "$top/models.toml" check --repo "$top" 2>&1); then
    ok "models.toml is consistent with licenses/, NOTICE, README.md and docs/models.md"
else
    fail "models.toml check: $out"
fi
mapfile -t ids < <(py --models "$top/models.toml" ids)
if [[ ${ids[*]} == "mediapipe-landscape pphumanseg-v2-mobile pphumanseg-v2-lite modnet" ]]; then
    ok "the four ids, in order"
else
    fail "ids: ${ids[*]}"
fi
# The file names are what consumers download: they must never change.
want_files="selfie_segmentation_landscape.onnx pp_humansegv2_mobile_192x192.onnx pp_humansegv2_lite_192x192.onnx modnet_photographic.onnx"
files=()
for id in "${ids[@]}"; do files+=("$(py --models "$top/models.toml" get "$id" file)"); done
if [[ ${files[*]} == "$want_files" ]]; then ok "the release file names"; else fail "file names: ${files[*]}"; fi
if [[ $(py --models "$top/models.toml" ids --kind paddle | tr '\n' ' ') == "pphumanseg-v2-mobile pphumanseg-v2-lite " ]]; then
    ok "ids --kind paddle"
else
    fail "ids --kind paddle"
fi
mapfile -t urls < <(py --models "$top/models.toml" get modnet input_urls)
if ((${#urls[@]} == 2)) && [[ ${urls[0]} == https://drive.usercontent.google.com/* &&
    ${urls[1]} =~ ^https://huggingface\.co/Xenova/modnet/resolve/[0-9a-f]{40}/onnx/model\.onnx$ ]]; then
    ok "MODNet: Google Drive first, then Hugging Face pinned to a commit"
else
    fail "MODNet URLs: ${urls[*]}"
fi
if [[ $(py --models "$top/models.toml" get mediapipe-landscape input.name) == input_1 &&
    $(py --models "$top/models.toml" get pphumanseg-v2-lite output.name) == save_infer_model/scale_0.tmp_0 ]]; then
    ok "get with a dotted key"
else
    fail "get with a dotted key"
fi
# Only MediaPipe's conversion is not byte-reproducible; its release file is
# the reference conversion, checked for equivalence at 1e-6.
rep=()
for id in "${ids[@]}"; do rep+=("$(py --models "$top/models.toml" reproducible "$id")"); done
if [[ ${rep[*]} == "no yes yes yes" ]]; then ok "reproducible: MediaPipe no, the others yes"; else fail "reproducible: ${rep[*]}"; fi
if [[ $(py --models "$top/models.toml" get mediapipe-landscape equivalence_tolerance) == 1e-06 ]]; then
    ok "MediaPipe's equivalence tolerance is 1e-6"
else
    fail "MediaPipe's equivalence tolerance"
fi
if [[ $(py --models "$top/models.toml" get mediapipe-landscape tf2onnx_opset) == 17 ]]; then
    ok "MediaPipe converts at opset 17"
else
    fail "MediaPipe's opset"
fi
# The ai.onnx opset each release file declares (convert/verify_model.py
# checks it): lite is exported at 14 (paddle2onnx raises 13 for hard_swish).
opsets=()
for id in "${ids[@]}"; do opsets+=("$(py --models "$top/models.toml" get "$id" opset)"); done
if [[ ${opsets[*]} == "17 13 14 11" ]]; then ok "opsets: MediaPipe 17, mobile 13, lite 14, MODNet 11"; else fail "opsets: ${opsets[*]}"; fi
if grep -q 'exports at opset 14' "$top/licenses/pphumanseg-v2-lite/NOTICE" &&
    ! grep -q 'opset 14' "$top/licenses/pphumanseg-v2-mobile/NOTICE"; then
    ok "the lite NOTICE states opset 14, the mobile one does not"
else
    fail "the PP-HumanSeg notices and their opsets"
fi
# Training data whose terms are not confirmed is labelled so, as in
# docs/models.md.
unconfirmed=()
for id in "${ids[@]}"; do
    [[ $(py --models "$top/models.toml" get "$id" training_data) != UNCONFIRMED:* ]] || unconfirmed+=("$id")
done
if [[ ${unconfirmed[*]} == "pphumanseg-v2-mobile pphumanseg-v2-lite modnet" ]] &&
    (($(grep -c '| Training data | \*\*UNCONFIRMED\.\*\*' "$top/docs/models.md") == 2)); then
    ok "training data UNCONFIRMED for PP-HumanSeg and MODNet, in models.toml and docs/models.md"
else
    fail "UNCONFIRMED training data: ${unconfirmed[*]}"
fi
status=0
py --models "$top/models.toml" get no-such-id file >/dev/null 2>&1 || status=$?
if ((status == 2)); then ok "an unknown id exits 2"; else fail "an unknown id exits $status, want 2"; fi
# Every licence file of one licence is the same text, and the repository's
# own Apache licence is that text too.
if cmp -s "$top/licenses/modnet/LICENSE" "$top/LICENSE-APACHE"; then
    ok "licenses/*/LICENSE is the Apache-2.0 text of LICENSE-APACHE"
else
    fail "licenses/modnet/LICENSE differs from LICENSE-APACHE"
fi
# requirements/: every line a comment or an exact pin.
bad=$(grep -hvE '^(#.*|[A-Za-z0-9._-]+==[A-Za-z0-9.+!-]+)?$' "$top"/requirements/*.txt || true)
if [[ -z $bad ]]; then ok "requirements/*.txt pin every package exactly"; else fail "unpinned requirement lines: $bad"; fi
for pin in tf2onnx==1.17.0 tensorflow-cpu==2.21.0 onnx==1.23.2 numpy==2.5.4 protobuf==7.36.2; do
    grep -qx "$pin" "$top/requirements/tflite.txt" || fail "requirements/tflite.txt lacks $pin"
done
for pin in paddlepaddle==2.6.2 paddle2onnx==1.3.1 onnx==1.23.2 numpy==2.2.6 protobuf==7.36.2; do
    grep -qx "$pin" "$top/requirements/paddle.txt" || fail "requirements/paddle.txt lacks $pin"
done
for pin in onnxruntime==1.31.1 onnx==1.23.2 numpy==2.5.4; do
    grep -qx "$pin" "$top/requirements/verify.txt" || fail "requirements/verify.txt lacks $pin"
done
ok "the tool pins of the reference build"
# requirements/<name>.lock (scripts/lock-requirements.sh): the same packages
# and versions as the .txt, every one with at least one hash, from PyPI only.
for name in tflite paddle verify; do
    lock=$top/requirements/$name.lock
    if [[ ! -f $lock ]]; then
        fail "requirements/$name.lock is missing"
        continue
    fi
    want=$(grep -vE '^[[:space:]]*(#|$)' "$top/requirements/$name.txt" | LC_ALL=C sort)
    got=$(grep -oE '^[A-Za-z0-9._-]+==[^ ;]+' "$lock" | LC_ALL=C sort)
    if [[ $got == "$want" ]]; then
        ok "requirements/$name.lock pins exactly the packages of requirements/$name.txt"
    else
        fail "requirements/$name.lock differs from requirements/$name.txt: $(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") || true)"
    fi
    if python3 -I -c '
import re, sys
text = open(sys.argv[1]).read().replace("\\\n", " ")
reqs = [l for l in text.splitlines() if re.match(r"^[A-Za-z0-9._-]+==", l)]
assert reqs, "no requirement"
for l in reqs:
    assert re.search(r"--hash=sha256:[0-9a-f]{64}", l), l.split()[0]
assert not re.search(r"^\s*(-i|--index-url|--extra-index-url|-f|--find-links|--trusted-host)\b", text, re.M)
' "$lock"; then
        ok "requirements/$name.lock: a sha256 hash for every package, no index option"
    else
        fail "requirements/$name.lock: a package without a hash, or an index option"
    fi
done

# A copy of the repository files the check reads, with one alteration.
# mutate <description> <python statement on `s` (the file text)> <file>
fixture() {
    local dir
    dir=$(mktemp -d "$tmp/repo.XXXXXX")
    cp -r "$top/models.toml" "$top/NOTICE" "$top/README.md" "$top/licenses" "$dir/"
    mkdir -p "$dir/docs"
    cp "$top/docs/models.md" "$dir/docs/"
    printf '%s\n' "$dir"
}
# expect_bad <description> <file to alter> <python expression of s> <expected message>
expect_bad() {
    local desc=$1 file=$2 expr=$3 want=$4 dir out status=0
    dir=$(fixture)
    python3 -I -c 'import sys; p=sys.argv[1]; s=open(p).read(); t=eval(sys.argv[2]); assert t != s, "fixture unchanged"; open(p, "w").write(t)' \
        "$dir/$file" "$expr"
    out=$(python3 -I "$models_py" --models "$dir/models.toml" check --repo "$dir" 2>&1) || status=$?
    if ((status != 1)); then
        fail "$desc (exit $status, want 1): $out"
    elif ! grep -qF -- "$want" <<<"$out"; then
        fail "$desc (no '$want'): $out"
    else
        ok "$desc"
    fi
}

echo "== defects the check must catch"
expect_bad "a missing field" models.toml \
    's.replace("training_data = \"UNCONFIRMED: not named", "# training_data = \"UNCONFIRMED: not named", 1)' \
    "modnet: missing or empty field training_data"
expect_bad "an output sha256 that is not 64 hex digits" models.toml \
    's.replace("sha256 = \"07c308cf", "sha256 = \"07C308CF", 1)' \
    "modnet: sha256 is not 64 lowercase hex digits"
expect_bad "an input sha256 too short" models.toml \
    's.replace("input_sha256 = \"a77d03f4", "input_sha256 = \"a77d03f", 1)' \
    "mediapipe-landscape: input_sha256 is not 64 lowercase hex digits"
expect_bad "a duplicate file name" models.toml \
    's.replace("file = \"pp_humansegv2_lite_192x192.onnx\"", "file = \"pp_humansegv2_mobile_192x192.onnx\"", 1)' \
    "duplicate file 'pp_humansegv2_mobile_192x192.onnx'"
expect_bad "a duplicate id" models.toml \
    's.replace("id = \"pphumanseg-v2-lite\"", "id = \"pphumanseg-v2-mobile\"", 1)' \
    "duplicate id 'pphumanseg-v2-mobile'"
expect_bad "a plain-http source" models.toml \
    's.replace("\"https://storage.googleapis.com/mediapipe-assets/selfie", "\"http://storage.googleapis.com/mediapipe-assets/selfie", 1)' \
    "every input_urls entry must be an https:// URL"
expect_bad "an unknown kind" models.toml 's.replace("kind = \"copy\"", "kind = \"onnxsim\"", 1)' \
    "modnet: unknown kind 'onnxsim'"
expect_bad "a copy whose checksums differ" models.toml \
    's.replace("input_sha256 = \"07c308cf", "input_sha256 = \"17c308cf", 1)' \
    "modnet: kind copy: sha256 and input_sha256 differ"
expect_bad "a dynamic shape without a smoke shape" models.toml \
    's.replace("smoke_shape = [1, 3, 288, 512]\n", "", 1)' \
    "modnet: a dynamic input shape needs input.smoke_shape"
expect_bad "a size that is not a number" models.toml 's.replace("size = 449893", "size = \"449893\"", 1)' \
    "mediapipe-landscape: size is not a positive integer"
expect_bad "reproducible that is not a boolean" models.toml \
    's.replace("\nreproducible = false", "\nreproducible = \"no\"", 1)' \
    "mediapipe-landscape: reproducible must be true or false"
expect_bad "reproducible = false without a tolerance" models.toml \
    's.replace("\nequivalence_tolerance = 1e-6\n", "\n", 1)' \
    "mediapipe-landscape: reproducible = false needs equivalence_tolerance"
expect_bad "an equivalence tolerance that is too large" models.toml \
    's.replace("equivalence_tolerance = 1e-6", "equivalence_tolerance = 0.01", 1)' \
    "mediapipe-landscape: reproducible = false needs equivalence_tolerance, a float in [0, 1e-3]"
expect_bad "an equivalence tolerance that is not a float" models.toml \
    's.replace("equivalence_tolerance = 1e-6", "equivalence_tolerance = \"1e-6\"", 1)' \
    "mediapipe-landscape: reproducible = false needs equivalence_tolerance"
expect_bad "a tolerance on a reproducible model" models.toml \
    's.replace("\nreproducible = false\n", "\n", 1)' \
    "mediapipe-landscape: equivalence_tolerance is only for a model with reproducible = false"
expect_bad "a copied model marked not reproducible" models.toml \
    's.replace("kind = \"copy\"", "kind = \"copy\"\nreproducible = false\nequivalence_tolerance = 0.0", 1)' \
    "modnet: kind copy: a copied file is always reproducible"
expect_bad "a missing opset" models.toml 's.replace("\nopset = 11\n", "\n", 1)' \
    "modnet: opset must be a positive integer"
expect_bad "a tflite opset other than tf2onnx_opset" models.toml 's.replace("\nopset = 17\n", "\nopset = 16\n", 1)' \
    "mediapipe-landscape: kind tflite: opset 16 differs from tf2onnx_opset 17"
expect_bad "a conversion naming another opset" models.toml \
    's.replace("asked for opset 13, exports at opset 14", "at opset 13", 1)' \
    "pphumanseg-v2-lite: conversion mentions an opset but not opset 14"
expect_bad "a NOTICE naming another opset" licenses/pphumanseg-v2-lite/NOTICE \
    's.replace("asked for opset\n13, which exports at opset 14, the opset its hard_swish operator needs", "at opset 13", 1)' \
    "pphumanseg-v2-lite: licenses/pphumanseg-v2-lite/NOTICE mentions an opset but not opset 14"
expect_bad "README.md listing another sha256" README.md \
    's.replace("fa02222275c455638fa1190493b659d25ad31e86f1b6459f17bd501f02cbe43d", "fa02222275c455638fa1190493b659d25ad31e86f1b6459f17bd501f02cbe43e")' \
    "mediapipe-landscape: README.md does not list fa02222275c455638fa1190493b659d25ad31e86f1b6459f17bd501f02cbe43d"
expect_bad "a stray checksum in README.md" README.md \
    's + "\nold: `0000000000000000000000000000000000000000000000000000000000000000`\n"' \
    "README.md: checksum 0000000000000000000000000000000000000000000000000000000000000000 is not in the model table"
expect_bad "docs/models.md missing an input sha256" docs/models.md \
    's.replace("9d86bc9c86c282cc2e92eaa089b96e18d30776c6ca745be18e6251a4e2a00110", "(see the table)")' \
    "pphumanseg-v2-lite: docs/models.md does not list 9d86bc9c86c282cc2e92eaa089b96e18d30776c6ca745be18e6251a4e2a00110"
expect_bad "README.md missing a size" README.md 's.replace("| 12205830 |", "| 12 MB |")' \
    "pphumanseg-v2-lite: README.md does not list 12205830"
expect_bad "a NOTICE missing a model's notice" NOTICE 's.replace("MODNet: Trimap-Free", "MODNet, trimap-free")' \
    "modnet: NOTICE does not hold licenses/modnet/NOTICE"

dir=$(fixture)
rm "$dir/licenses/pphumanseg-v2-mobile/NOTICE"
status=0
out=$(py --models "$dir/models.toml" check --repo "$dir" 2>&1) || status=$?
if ((status == 1)) && grep -qF 'licenses/pphumanseg-v2-mobile/NOTICE' <<<"$out"; then
    ok "a missing licence NOTICE"
else
    fail "a missing licence NOTICE (exit $status): $out"
fi
dir=$(fixture)
printf 'another licence\n' >"$dir/licenses/modnet/LICENSE"
status=0
out=$(py --models "$dir/models.toml" check --repo "$dir" 2>&1) || status=$?
if ((status == 1)) && grep -qF 'licenses/modnet/LICENSE differs' <<<"$out"; then
    ok "licence files of one licence that differ"
else
    fail "licence files of one licence that differ (exit $status): $out"
fi
printf 'not = [toml\n' >"$tmp/broken.toml"
status=0
py --models "$tmp/broken.toml" ids >/dev/null 2>&1 || status=$?
if ((status == 2)); then ok "an unreadable table exits 2"; else fail "an unreadable table exits $status, want 2"; fi

if ((fails > 0)); then
    echo "$fails of $count check(s) failed"
    exit 1
fi
echo "all $count checks passed"
