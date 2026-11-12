#!/usr/bin/env bash
# shellcheck disable=SC2016 # Python and sh -c programs in single quotes, on purpose
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Tests of the build's functions, without network and without the conversion
# environments: scripts/lib/common.sh (checksums, SHA256SUMS, verified
# downloads with a fake downloader, safe extraction, build facts) and the
# manifest writer of scripts/lib/models.py, on small fake files under mktemp;
# and the option handling of scripts/build-models.sh, and its handling of the
# reference file of a model that is not byte-reproducible, up to the point
# where it would create an environment (a fake uv stops it there), in a copy
# of the repository under mktemp; then, in the same copy with a fake uv whose
# environments hold a fake interpreter, whole builds: the uv options and
# environment, a checksum mismatch and a wrong --input-dir file leaving dist
# untouched, the --dist marker and the refusal of a foreign --dist, and
# --keep-venvs with a kept environment of another Python.
# Usage: scripts/tests/build-lib-test.sh. Exits non-zero on any failure.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
top=$(cd "$here/../.." && pwd)
# shellcheck source=scripts/lib/common.sh
. "$top/scripts/lib/common.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fails=0 count=0
ok() { count=$((count + 1)); echo "ok   $1"; }
fail() { count=$((count + 1)); echo "FAIL $1"; fails=$((fails + 1)); }
# check <description> <command...>: the command must succeed.
check() {
    local desc=$1
    shift
    if "$@" >"$tmp/out" 2>&1; then ok "$desc"; else fail "$desc: $(cat "$tmp/out")"; fi
}
# refuse <description> <expected status> <command...>
refuse() {
    local desc=$1 want=$2 status=0
    shift 2
    "$@" >"$tmp/out" 2>&1 || status=$?
    if ((status == want)); then ok "$desc"; else fail "$desc (exit $status, want $want): $(cat "$tmp/out")"; fi
}

empty_sha=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
printf 'hello\n' >"$tmp/hello.txt"
hello_sha=5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03

echo "== checksums"
check "sha256_of of an empty file" test "$(: >"$tmp/empty"; sha256_of "$tmp/empty")" = "$empty_sha"
check "sha256_of of a small file" test "$(sha256_of "$tmp/hello.txt")" = "$hello_sha"
check "is_sha256 accepts 64 lowercase hex digits" is_sha256 "$hello_sha"
refuse "is_sha256 refuses upper case" 1 is_sha256 "${hello_sha^^}"
refuse "is_sha256 refuses 63 digits" 1 is_sha256 "${hello_sha:1}"
check "verify_sha256 accepts the right checksum" verify_sha256 "$tmp/hello.txt" "$hello_sha"
refuse "verify_sha256 refuses another checksum" 1 verify_sha256 "$tmp/hello.txt" "$empty_sha"
refuse "verify_sha256 refuses a malformed checksum" 1 verify_sha256 "$tmp/hello.txt" xyz
refuse "verify_sha256 refuses a missing file" 1 verify_sha256 "$tmp/nope" "$hello_sha"

echo "== SHA256SUMS"
dist=$tmp/dist
mkdir -p "$dist"
printf 'model a\n' >"$dist/a.onnx"
printf 'model b\n' >"$dist/b_192x192.onnx"
printf 'licence\n' >"$dist/LICENSE-Apache-2.0"
printf 'notice\n' >"$dist/NOTICE"
check "write_sha256sums" write_sha256sums "$dist"
check "sha256sum -c accepts the written file" sh -c 'cd "$1" && sha256sum -c --strict --quiet SHA256SUMS' sh "$dist"
check "SHA256SUMS lists every file but itself, sorted" test \
    "$(cut -c67- "$dist/SHA256SUMS" | tr '\n' ' ')" = "LICENSE-Apache-2.0 NOTICE a.onnx b_192x192.onnx "
check "SHA256SUMS lines are '<sha256>  <name>'" \
    grep -qxE "[0-9a-f]{64}  a\.onnx" "$dist/SHA256SUMS"
check "check_sha256sums accepts it" check_sha256sums "$dist"
printf 'tampered\n' >>"$dist/a.onnx"
refuse "check_sha256sums refuses a changed file" 1 check_sha256sums "$dist"
check "write_sha256sums again" write_sha256sums "$dist"
printf 'late\n' >"$dist/extra.onnx"
refuse "check_sha256sums refuses an unlisted file" 1 check_sha256sums "$dist"
rm "$dist/extra.onnx"
mkdir -p "$tmp/plus"
printf 'p\n' >"$tmp/plus/a+b.onnx"
check "write_sha256sums with a + in a file name" write_sha256sums "$tmp/plus"
check "check_sha256sums matches the + literally" check_sha256sums "$tmp/plus"
mkdir -p "$tmp/plus2"
printf 'p\n' >"$tmp/plus2/aab.onnx"
write_sha256sums "$tmp/plus2"
mv "$tmp/plus2/aab.onnx" "$tmp/plus2/a+b.onnx"
cp "$tmp/plus2/a+b.onnx" "$tmp/plus2/aab.onnx"
check "the listed aab.onnx is fine" sh -c '. "$1/scripts/lib/common.sh"; (cd "$2" && sha256sum -c --quiet SHA256SUMS)' sh "$top" "$tmp/plus2"
refuse "an unlisted a+b.onnx is not covered by a listed aab.onnx" 1 check_sha256sums "$tmp/plus2"
mkdir -p "$tmp/dot"
printf 'p\n' >"$tmp/dot/aXonnx"
write_sha256sums "$tmp/dot"
cp "$tmp/dot/aXonnx" "$tmp/dot/a.onnx"
refuse "an unlisted a.onnx is not covered by a listed aXonnx" 1 check_sha256sums "$tmp/dot"
mkdir -p "$tmp/odd"
printf 'x\n' >"$tmp/odd/a b.onnx"
refuse "write_sha256sums refuses a file name with a space" 1 write_sha256sums "$tmp/odd"
mkdir -p "$tmp/none"
refuse "write_sha256sums refuses an empty directory" 1 write_sha256sums "$tmp/none"

echo "== verified downloads (fake downloader)"
# The fake downloader serves files from $tmp/server by URL path; an URL under
# fail:// fails like a network error. It records every URL it is asked for.
mkdir -p "$tmp/server"
printf 'original\n' >"$tmp/server/good.bin"
printf 'tampered\n' >"$tmp/server/bad.bin"
good_sha=$(sha256_of "$tmp/server/good.bin")
download_one() {
    echo "$1" >>"$tmp/asked"
    case $1 in
        fail://*) return 1 ;;
        test://*) cp -- "$tmp/server/${1#test://}" "$2" ;;
        *) return 1 ;;
    esac
}
: >"$tmp/asked"
check "fetch_verified from the first URL" fetch_verified "$tmp/in1" model.onnx "$good_sha" test://good.bin test://bad.bin
fetch_verified "$tmp/in1b" model.onnx "$good_sha" test://good.bin 2>/dev/null
check "FETCHED_URL is the first URL" test "$FETCHED_URL" = test://good.bin
check "FETCHED_PATH is a verified file in its own new directory" \
    sh -c '[ "$(dirname "$1")" != "$2" ] && [ "$(dirname "$(dirname "$1")")" = "$2" ] && cmp -s "$1" "$3"' \
    sh "$FETCHED_PATH" "$tmp/in1b" "$tmp/server/good.bin"
: >"$tmp/asked"
fetch_verified "$tmp/in2" model.onnx "$good_sha" fail://down test://good.bin 2>/dev/null
check "a failed download moves on to the mirror" test "$FETCHED_URL" = test://good.bin
check "the failed attempt's directory is removed" test "$(find "$tmp/in2" -mindepth 1 -maxdepth 1 | wc -l)" = 1
: >"$tmp/asked"
# A host may answer HTTP 200 with a quota or error page: that file fails its
# checksum, is discarded, and the next URL is tried against the same one.
fetch_verified "$tmp/in3" model.onnx "$good_sha" test://bad.bin test://good.bin 2>/dev/null
check "a checksum mismatch falls back to the mirror" test "$FETCHED_URL" = test://good.bin
check "both URLs were asked, in order" test "$(tr '\n' ' ' <"$tmp/asked")" = "test://bad.bin test://good.bin "
check "the mirror's file is the verified one" cmp -s "$FETCHED_PATH" "$tmp/server/good.bin"
check "the rejected download is removed" test "$(find "$tmp/in3" -mindepth 1 -maxdepth 1 | wc -l)" = 1
: >"$tmp/asked"
refuse "every URL giving another file is status 3" 3 \
    fetch_verified "$tmp/in3b" model.onnx "$good_sha" test://bad.bin test://bad.bin
check "every URL was asked" test "$(wc -l <"$tmp/asked")" = 2
check "no rejected download is left" test "$(find "$tmp/in3b" -mindepth 1 | wc -l)" = 0
refuse "a wrong file then a failed download is status 3" 3 \
    fetch_verified "$tmp/in3c" model.onnx "$good_sha" test://bad.bin fail://down
check "FETCHED_PATH is empty after a failure" test -z "$FETCHED_PATH"
refuse "no URL answering is status 1" 1 fetch_verified "$tmp/in4" model.onnx "$good_sha" fail://a fail://b
refuse "a file name with a slash is refused" 2 fetch_verified "$tmp/in5" ../model.onnx "$good_sha" test://good.bin

mkdir -p "$tmp/local"
cp "$tmp/server/good.bin" "$tmp/local/model.onnx"
check "reuse_verified copies a local original" reuse_verified "$tmp/local" "$tmp/in6" model.onnx "$good_sha"
reuse_verified "$tmp/local" "$tmp/in6b" model.onnx "$good_sha"
check "reuse_verified records a file:// URL" test "$FETCHED_URL" = "file://$tmp/local/model.onnx"
refuse "reuse_verified of a missing file is status 1" 1 reuse_verified "$tmp/local" "$tmp/in7" other.onnx "$good_sha"
cp "$tmp/server/bad.bin" "$tmp/local/model.onnx"
refuse "reuse_verified of a wrong file is status 3" 3 reuse_verified "$tmp/local" "$tmp/in8" model.onnx "$good_sha"
if (($(id -u) != 0)); then
    cp "$tmp/server/good.bin" "$tmp/local/locked.onnx"
    chmod 000 "$tmp/local/locked.onnx"
    refuse "reuse_verified of a file it cannot copy is status 2, not a wrong checksum" 2 \
        reuse_verified "$tmp/local" "$tmp/in9" locked.onnx "$good_sha"
    cp "$tmp/out" "$tmp/locked.out"
    check "the message names the copy failure" sh -c 'grep -q "could not copy" "$1" && ! grep -q "wrong checksum" "$1"' sh "$tmp/locked.out"
    check "the failed copy leaves no directory" test "$(find "$tmp/in9" -mindepth 1 | wc -l)" = 0
    chmod 600 "$tmp/local/locked.onnx"
else
    echo "skip: running as root (reuse_verified of an unreadable file)"
fi

echo "== safe extraction"
mkzip() { # mkzip <zip> <arcname>...: a zip with one small member per name
    python3 -I -c 'import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    for n in sys.argv[2:]: z.writestr(n, "x\n")' "$@"
}
mkzip "$tmp/ok.zip" model_dir/model.pdmodel model_dir/model.pdiparams
check "safe_unzip extracts a normal archive" safe_unzip "$tmp/ok.zip" "$tmp/x1"
check "the members are in place" test -f "$tmp/x1/model_dir/model.pdiparams"
refuse "safe_unzip refuses an existing destination" 1 safe_unzip "$tmp/ok.zip" "$tmp/x1"
mkzip "$tmp/up.zip" model_dir/a ../escape
refuse "safe_unzip refuses a .. entry" 1 safe_unzip "$tmp/up.zip" "$tmp/x2"
check "nothing was extracted" test ! -e "$tmp/x2" -a ! -e "$tmp/escape"
mkzip "$tmp/abs.zip" /etc/evil
refuse "safe_unzip refuses an absolute entry" 1 safe_unzip "$tmp/abs.zip" "$tmp/x3"
python3 -I -c 'import sys, zipfile
z = zipfile.ZipFile(sys.argv[1], "w")
i = zipfile.ZipInfo("link")
i.external_attr = (0o120777 << 16)
z.writestr(i, "/etc/passwd")
z.close()' "$tmp/link.zip"
refuse "safe_unzip refuses a symbolic link" 1 safe_unzip "$tmp/link.zip" "$tmp/x4"
python3 -I -W ignore -c 'import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("d/model.pdmodel", "first\n")
    z.writestr("d/model.pdmodel", "second\n")' "$tmp/dup.zip"
# Without -n, unzip would ask whether to replace the first entry (and, with
# no terminal, fail); with it, nothing is asked.
check "safe_unzip of duplicate entries never asks" safe_unzip "$tmp/dup.zip" "$tmp/x5"
check "of two entries with one name, the first is kept" test "$(cat "$tmp/x5/d/model.pdmodel")" = first

echo "== build facts and the manifest"
facts=$tmp/facts.tsv
: >"$facts"
check "fact records a line" fact "$facts" python.verify 3.12.16
refuse "fact refuses a value with a newline" 1 fact "$facts" k $'a\nb'
fact "$facts" freeze.verify "numpy==2.5.4 onnx==1.23.2 onnxruntime==1.31.1"
fact "$facts" python.paddle 3.10.22
fact "$facts" freeze.paddle "paddle2onnx==1.3.1 paddlepaddle==2.6.2"
fact "$facts" pphumanseg-v2-lite.fetched_url test://lite.zip
fact "$facts" pphumanseg-v2-lite.steps "pp_static; paddle2onnx"
fact "$facts" pphumanseg-v2-lite.provenance "built from the original; byte-identical to models.toml"
fact "$facts" modnet.fetched_url test://modnet.onnx
fact "$facts" modnet.provenance "built from the original; byte-identical to models.toml"
fact "$facts" source_revision 0123abc
mdist=$tmp/mdist
mkdir -p "$mdist"
printf 'fake lite\n' >"$mdist/pp_humansegv2_lite_192x192.onnx"
printf 'fake modnet\n' >"$mdist/modnet_photographic.onnx"
printf 'licence\n' >"$mdist/LICENSE-Apache-2.0"
printf 'notice\n' >"$mdist/NOTICE"
check "models.py manifest writes MANIFEST.toml" \
    python3 -I "$top/scripts/lib/models.py" --models "$top/models.toml" manifest "$mdist" "$facts"
check "the manifest parses and describes the files present" python3 -I -c '
import hashlib, os, sys, tomllib
d = sys.argv[1]
m = tomllib.load(open(os.path.join(d, "MANIFEST.toml"), "rb"))
names = [f["name"] for f in m["file"]]
assert names == ["pp_humansegv2_lite_192x192.onnx", "modnet_photographic.onnx"], names
for f in m["file"] + m["extra"]:
    p = os.path.join(d, f["name"])
    assert f["size"] == os.path.getsize(p), f
    assert f["sha256"] == hashlib.sha256(open(p, "rb").read()).hexdigest(), f
lite, modnet = m["file"]
assert lite["source_fetched_from"] == "test://lite.zip"
assert lite["source_sha256"] == "9d86bc9c86c282cc2e92eaa089b96e18d30776c6ca745be18e6251a4e2a00110"
assert lite["conversion_tools"] == ["python==3.10.22", "paddle2onnx==1.3.1", "paddlepaddle==2.6.2"], lite
assert lite["conversion_steps"] == "pp_static; paddle2onnx"
assert lite["verified_with"][0] == "python==3.12.16"
assert lite["licence"] == "Apache-2.0" and lite["licence_file"] == "LICENSE-Apache-2.0"
assert lite["input_shape"] == [1, 3, 192, 192] and lite["output_name"] == "save_infer_model/scale_0.tmp_0"
assert modnet["conversion_tools"] == [] and modnet["input_shape"][0] == "batch_size"
assert len(modnet["source_urls"]) == 2
assert [e["name"] for e in m["extra"]] == ["LICENSE-Apache-2.0", "NOTICE"]
assert m["source_revision"] == "0123abc"
assert lite["reproducible"] is True and lite["provenance"].endswith("byte-identical to models.toml")
assert "equivalence" not in lite and "reference_source" not in lite
' "$mdist"
check "the manifest is the same when written again (no timestamps)" sh -c '
cp "$1/MANIFEST.toml" "$3/first.toml"
python3 -I "$2/scripts/lib/models.py" --models "$2/models.toml" manifest "$1" "$4"
cmp -s "$1/MANIFEST.toml" "$3/first.toml"' sh "$mdist" "$top" "$tmp" "$facts"
check "SHA256SUMS covers the manifest" sh -c '. "$1/scripts/lib/common.sh"; write_sha256sums "$2" && grep -q "  MANIFEST.toml$" "$2/SHA256SUMS" && check_sha256sums "$2"' sh "$top" "$mdist"
sed -i '/modnet.fetched_url/d' "$facts"
refuse "a missing build fact is an error (status 2)" 2 \
    python3 -I "$top/scripts/lib/models.py" --models "$top/models.toml" manifest "$mdist" "$facts"

echo "== the manifest of a reference file (reproducible = false)"
efacts=$tmp/efacts.tsv
: >"$efacts"
fact "$efacts" python.verify 3.12.16
fact "$efacts" freeze.verify "numpy==2.5.4 onnx==1.23.2 onnxruntime==1.31.1"
fact "$efacts" python.tflite 3.12.16
fact "$efacts" freeze.tflite "tf2onnx==1.17.0"
fact "$efacts" mediapipe-landscape.fetched_url test://mp.tflite
fact "$efacts" mediapipe-landscape.provenance "reference conversion, verified equivalent"
fact "$efacts" mediapipe-landscape.reference_source "supplied with --reference-dir, SHA-256 checked against models.toml"
printf 'fresh\n' >"$tmp/fresh.onnx"
fresh_sha=$(sha256_of "$tmp/fresh.onnx")
printf '{"equivalent": true, "tolerance": 1e-06, "max_abs_diff": 0.0, "probes": ["smoke", "low"], "initializers": 123, "nodes_compared": 174, "ignored_reference": 13, "ignored_fresh": 14, "fresh_sha256": "%s", "fresh_size": 6}' \
    "$fresh_sha" >"$tmp/result.json"
python3 -I -B -c 'import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("equivalence", sys.argv[1])
eq = importlib.util.module_from_spec(spec)
spec.loader.exec_module(eq)
with open(sys.argv[3], "a") as f:
    for k, v in eq.facts(json.load(open(sys.argv[2])), "mediapipe-landscape"):
        f.write(f"{k}\t{v}\n")' "$top/scripts/lib/equivalence.py" "$tmp/result.json" "$efacts"
edist=$tmp/edist
mkdir -p "$edist"
printf 'fake reference\n' >"$edist/selfie_segmentation_landscape.onnx"
check "models.py manifest writes the equivalence of a reference file" \
    python3 -I "$top/scripts/lib/models.py" --models "$top/models.toml" manifest "$edist" "$efacts"
check "the manifest records the provenance, the equivalence and the tolerance" python3 -I -c '
import os, sys, tomllib
m = tomllib.load(open(os.path.join(sys.argv[1], "MANIFEST.toml"), "rb"))
(f,) = m["file"]
assert f["reproducible"] is False, f
assert f["provenance"] == "reference conversion, verified equivalent", f
assert f["reference_source"].startswith("supplied with --reference-dir"), f
e = f["equivalence"]
assert e["result"] == "equivalent" and e["tolerance"] == 1e-6 and e["max_abs_diff"] == 0.0, e
assert e["fresh_sha256"] == sys.argv[2] and e["fresh_size"] == 6, e
assert e["probes"] == ["smoke", "low"] and e["initializers"] == 123 and e["nodes_compared"] == 174, e
assert e["ignored_nodes_reference"] == 13 and e["ignored_nodes_fresh"] == 14, e
assert e["ignored_rule"].startswith("a Reshape whose data input and output have the same"), e
assert e["same"] == ["ir_version", "opset_imports", "inputs", "outputs", "initializers", "nodes"], e
' "$edist" "$fresh_sha"
check "models.py and equivalence.py state the same no-op rule" python3 -I -B -c '
import importlib.util, sys
mods = []
for p in sys.argv[1:]:
    spec = importlib.util.spec_from_file_location("m%d" % len(mods), p)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mods.append(mod)
assert mods[0].NOOP_RULE_TEXT == mods[1].NOOP_RULE_TEXT' "$top/scripts/lib/models.py" "$top/scripts/lib/equivalence.py"
sed -i 's/^mediapipe-landscape.equivalence_tolerance\t.*/mediapipe-landscape.equivalence_tolerance\t1e-05/' "$efacts"
refuse "a tolerance other than the one in the table is an error (status 2)" 2 \
    python3 -I "$top/scripts/lib/models.py" --models "$top/models.toml" manifest "$edist" "$efacts"

echo "== build-models.sh options (no network)"
refuse "an unknown option exits 2" 2 "$top/scripts/build-models.sh" --bogus
refuse "--only without an id exits 2" 2 "$top/scripts/build-models.sh" --only
if command -v uv >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1; then
    refuse "an unknown --only id fails before any work" 1 "$top/scripts/build-models.sh" --only no-such-model
    cp "$tmp/out" "$tmp/only.out"
    check "the message names the id" grep -q 'unknown model id: no-such-model' "$tmp/only.out"
else
    echo "skip: uv, curl or unzip missing (build-models.sh --only no-such-model)"
fi

echo "== build-models.sh: the reference file of a model that is not byte-reproducible"
# A copy of the repository whose MediaPipe release checksum is that of a fake
# reference file (in every file that lists it, so that the table stays
# consistent), and a fake uv that stops the build where it would create the
# first environment: nothing is downloaded or converted.
repo=$tmp/repo
mkdir -p "$repo"
cp -r "$top/models.toml" "$top/NOTICE" "$top/README.md" "$top/licenses" "$top/scripts" \
    "$top/convert" "$top/requirements" "$top/docs" "$repo/"
printf 'fake reference model\n' >"$tmp/good-ref.onnx"
ref_sha=$(sha256_of "$tmp/good-ref.onnx")
pinned=$(python3 -I "$top/scripts/lib/models.py" --models "$top/models.toml" get mediapipe-landscape sha256)
sed -i "s/$pinned/$ref_sha/g" "$repo/models.toml" "$repo/README.md" "$repo/docs/models.md" "$repo/docs/release.md"
mkdir -p "$tmp/fakebin"
printf '#!/bin/sh\necho "fake uv: stopped at the first environment" >&2\nexit 97\n' >"$tmp/fakebin/uv"
chmod +x "$tmp/fakebin/uv"
mkdir -p "$tmp/refs-good" "$tmp/refs-bad" "$tmp/refs-none"
cp "$tmp/good-ref.onnx" "$tmp/refs-good/selfie_segmentation_landscape.onnx"
printf 'another file\n' >"$tmp/refs-bad/selfie_segmentation_landscape.onnx"
# build <output file> <args...>: runs the copy's build (MediaPipe only,
# unless the arguments name other models) with the fake uv; the
# exit status is printed into the output file's last line.
build() {
    local out=$1 status=0
    shift
    [[ " $* " == *" --only "* ]] || set -- --only mediapipe-landscape "$@"
    PATH=$tmp/fakebin:$PATH "$repo/scripts/build-models.sh" "$@" >"$out" 2>&1 || status=$?
    echo "exit $status" >>"$out"
}
if command -v curl >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1; then
    check "the copy's table is consistent" python3 -I "$repo/scripts/lib/models.py" --models "$repo/models.toml" check --repo "$repo"
    build "$tmp/b-none.out"
    check "no reference: the build stops before any environment" grep -qx 'exit 1' "$tmp/b-none.out"
    check "no reference: the message explains --reference-dir and --accept-new-checksums" \
        sh -c 'grep -q "not byte-reproducible" "$1" && grep -q -- "--reference-dir DIR with selfie_segmentation_landscape.onnx" "$1" && grep -q -- "--accept-new-checksums builds the fresh file" "$1" && ! grep -q "fake uv" "$1"' sh "$tmp/b-none.out"
    build "$tmp/b-empty.out" --reference-dir "$tmp/refs-none"
    check "a reference directory without the file is the same error" \
        sh -c 'grep -qx "exit 1" "$1" && grep -q "not byte-reproducible" "$1" && ! grep -q "fake uv" "$1"' sh "$tmp/b-empty.out"
    build "$tmp/b-bad.out" --reference-dir "$tmp/refs-bad"
    check "a reference with another SHA-256 is a hard failure before any environment" \
        sh -c 'grep -qx "exit 1" "$1" && grep -q "is not the release file: its SHA-256 must be $2" "$1" && ! grep -q "fake uv" "$1"' sh "$tmp/b-bad.out" "$ref_sha"
    build "$tmp/b-good.out" --reference-dir "$tmp/refs-good"
    check "a reference with the pinned SHA-256 is accepted, then the build goes on to the environments" \
        sh -c 'grep -q "reference selfie_segmentation_landscape.onnx verified ($2)" "$1" && grep -q "fake uv: stopped" "$1" && grep -qx "exit 97" "$1"' sh "$tmp/b-good.out" "$ref_sha"
    build "$tmp/b-accept.out" --accept-new-checksums
    check "no reference with --accept-new-checksums: a warning, then the build goes on" \
        sh -c 'grep -q "WARNING: mediapipe-landscape is not byte-reproducible and no reference was supplied" "$1" && grep -q "fake uv: stopped" "$1"' sh "$tmp/b-accept.out"
    build "$tmp/b-modnet.out" --only modnet
    check "a reproducible model alone needs no reference" \
        sh -c '! grep -q "not byte-reproducible" "$1" && grep -q "fake uv: stopped" "$1"' sh "$tmp/b-modnet.out"
    check "the work directories of the copy are removed" \
        sh -c '[ -z "$(find "$1/build" -mindepth 1 -maxdepth 1 -name "work.*")" ]' sh "$repo"
else
    echo "skip: curl or unzip missing (build-models.sh reference handling)"
fi

echo "== build-models.sh through the build, with a fake uv and fake interpreters"
# A fake uv that makes environments whose python is a fake interpreter:
# it reports the pinned version, answers the verification and the
# PP-HumanSeg steps with small fixed outputs, and fails on anything else.
# The fake uv records its arguments and the index variables it sees. In the
# copy, MODNet's checksums are those of a small fake file (so a copy build
# succeeds) and PP-HumanSeg lite's original is a small fake archive (whose
# fake conversion cannot have the pinned release checksum).
mkdir -p "$tmp/fakebin2"
cat >"$tmp/fakebin2/uv" <<'FAKEUV'
#!/usr/bin/env bash
{
    printf 'argv:'
    printf ' %s' "$@"
    printf '\n'
    printf 'env: UV_INDEX_URL=%s UV_EXTRA_INDEX_URL=%s UV_INDEX=%s PIP_INDEX_URL=%s\n' \
        "${UV_INDEX_URL-unset}" "${UV_EXTRA_INDEX_URL-unset}" "${UV_INDEX-unset}" "${PIP_INDEX_URL-unset}"
} >>"$FAKE_UV_LOG"
[[ ${1:-} == --no-config ]] || { echo "fake uv: called without --no-config" >&2; exit 96; }
shift
opt() { local want=$1 prev='' a; shift; for a in "$@"; do [[ $prev != "$want" ]] || { printf '%s\n' "$a"; return; }; prev=$a; done; }
case "${1:-} ${2:-}" in
    "venv "*)
        dir=${*: -1}
        mkdir -p "$dir/bin"
        cp "$FAKE_PYTHON" "$dir/bin/python"
        opt --python "$@" >"$dir/fake-version"
        ;;
    "pip sync") ;;
    "pip freeze")
        py=$(opt --python "$@")
        name=$(basename "$(dirname "$(dirname "$py")")")
        grep -vE '^[[:space:]]*(#|$)' "$FAKE_REPO/requirements/$name.txt"
        ;;
    *) echo "fake uv: unexpected: $*" >&2; exit 95 ;;
esac
FAKEUV
cat >"$tmp/fakepython" <<'FAKEPY'
#!/usr/bin/env bash
env_dir=$(cd "$(dirname "$0")/.." && pwd)
case "$*" in
    *"import platform"*) cat "$env_dir/fake-version" ;;
    *verify_model.py*) echo "fake verify: ok" ;;
    *pp_static.py*) mkdir -p "$4" ;;
    *pp_has_adaptive_pool.py*) echo no ;;
    *"paddle2onnx.command"*)
        while (($# > 0)); do
            if [[ $1 == --save_file ]]; then printf 'fake paddle2onnx export\n' >"$2"; exit 0; fi
            shift
        done
        exit 94
        ;;
    *) echo "fake python: unexpected: $*" >&2; exit 98 ;;
esac
FAKEPY
chmod +x "$tmp/fakebin2/uv" "$tmp/fakepython"
mkdir -p "$tmp/in-good" "$tmp/in-bad"
printf 'fake modnet export\n' >"$tmp/in-good/modnet.onnx"
modnet_fake=$(sha256_of "$tmp/in-good/modnet.onnx")
lite_dir=$(python3 -I "$top/scripts/lib/models.py" --models "$top/models.toml" get pphumanseg-v2-lite paddle_model_dir)
lite_zip=$(python3 -I "$top/scripts/lib/models.py" --models "$top/models.toml" get pphumanseg-v2-lite input_file)
mkzip "$tmp/in-good/$lite_zip" "$lite_dir/model.pdmodel" "$lite_dir/model.pdiparams"
lite_fake=$(sha256_of "$tmp/in-good/$lite_zip")
printf 'not the archive\n' >"$tmp/in-bad/$lite_zip"
for id in modnet pphumanseg-v2-lite; do
    key=sha256 new=$modnet_fake
    [[ $id == modnet ]] || key=input_sha256 new=$lite_fake
    old=$(python3 -I "$top/scripts/lib/models.py" --models "$top/models.toml" get "$id" "$key")
    sed -i "s/$old/$new/g" "$repo/models.toml" "$repo/README.md" "$repo/docs/models.md" "$repo/docs/release.md"
done
export FAKE_UV_LOG=$tmp/uv.log FAKE_PYTHON=$tmp/fakepython FAKE_REPO=$repo
# build2 <output file> <args...>: the copy's build with the fake uv; the exit
# status is the output file's last line. The index variables are set, to
# show that the build's uv never sees them.
build2() {
    local out=$1 status=0
    shift
    PATH=$tmp/fakebin2:$PATH UV_INDEX_URL=https://index.invalid/simple UV_EXTRA_INDEX_URL=https://extra.invalid/simple \
        UV_INDEX=https://named.invalid/simple PIP_INDEX_URL=https://pip.invalid/simple \
        "$repo/scripts/build-models.sh" "$@" >"$out" 2>&1 || status=$?
    echo "exit $status" >>"$out"
}
# snap <dir>: every file of <dir> (dot files too) with its SHA-256.
snap() { (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0r sha256sum); }
marker=.omarchy-onnx-models-dist
if command -v curl >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1; then
    check "the altered copy's table is consistent" python3 -I "$repo/scripts/lib/models.py" --models "$repo/models.toml" check --repo "$repo"
    d=$tmp/out-dist
    : >"$FAKE_UV_LOG"
    build2 "$tmp/c-new.out" --only modnet --input-dir "$tmp/in-good" --dist "$d"
    check "a copy build into an absent --dist succeeds" grep -qx 'exit 0' "$tmp/c-new.out"
    check "dist holds the release files and the marker" test \
        "$(cd "$d" && find . -type f | LC_ALL=C sort | tr '\n' ' ')" = "./$marker ./LICENSE-Apache-2.0 ./MANIFEST.toml ./NOTICE ./SHA256SUMS ./modnet_photographic.onnx "
    check "sha256sum -c accepts dist" sh -c 'cd "$1" && sha256sum -c --strict --quiet SHA256SUMS' sh "$d"
    check "the marker is in neither SHA256SUMS nor MANIFEST.toml" \
        sh -c '! grep -q "$2" "$1/SHA256SUMS" && ! grep -q "$2" "$1/MANIFEST.toml"' sh "$d" "$marker"
    check "every uv call has --no-config" sh -c '! grep "^argv:" "$1" | grep -qv "^argv: --no-config "' sh "$FAKE_UV_LOG"
    check "uv never sees an index variable" sh -c '! grep "^env:" "$1" | grep -qv "^env: UV_INDEX_URL=unset UV_EXTRA_INDEX_URL=unset UV_INDEX=unset PIP_INDEX_URL=unset$"' sh "$FAKE_UV_LOG"
    check "uv pip sync requires hashes, from PyPI only, from the lock file" \
        grep -qE "^argv: --no-config pip sync .*--require-hashes --default-index https://pypi\.org/simple .*/requirements/verify\.lock$" "$FAKE_UV_LOG"
    build2 "$tmp/c-again.out" --only modnet --input-dir "$tmp/in-good" --dist "$d"
    check "a second build replaces a --dist the build wrote (the marker)" grep -qx 'exit 0' "$tmp/c-again.out"

    before=$(snap "$d")
    build2 "$tmp/c-mismatch.out" --only pphumanseg-v2-lite --input-dir "$tmp/in-good" --dist "$d"
    check "a reproducible model with another checksum stops the build" \
        sh -c 'grep -qx "exit 1" "$1" && grep -q "pphumanseg-v2-lite: pp_humansegv2_lite_192x192.onnx sha256 MISMATCH" "$1" && grep -q "checksum mismatch for: pphumanseg-v2-lite; dist/ untouched" "$1"' sh "$tmp/c-mismatch.out"
    check "... and leaves dist as it was" test "$(snap "$d")" = "$before"
    build2 "$tmp/c-badin.out" --only pphumanseg-v2-lite --input-dir "$tmp/in-bad" --dist "$d"
    check "a file of --input-dir with another checksum is rejected" \
        sh -c 'grep -qx "exit 1" "$1" && grep -q "has the wrong checksum" "$1" && ! grep -q "fake paddle2onnx\|MISMATCH" "$1"' sh "$tmp/c-badin.out"
    check "... and leaves dist as it was" test "$(snap "$d")" = "$before"

    mkdir -p "$tmp/foreign"
    printf 'my notes\n' >"$tmp/foreign/notes.txt"
    before=$(snap "$tmp/foreign")
    : >"$FAKE_UV_LOG"
    build2 "$tmp/c-foreign.out" --only modnet --input-dir "$tmp/in-good" --dist "$tmp/foreign"
    check "a foreign --dist is refused before any work" \
        sh -c 'grep -qx "exit 1" "$1" && grep -q "has no $2" "$1" && [ ! -s "$3" ]' sh "$tmp/c-foreign.out" "$marker" "$FAKE_UV_LOG"
    check "... and left untouched" test "$(snap "$tmp/foreign")" = "$before"
    mkdir -p "$tmp/lookalike"
    printf 'x\n' >"$tmp/lookalike/old.onnx"
    printf 'y\n' >"$tmp/lookalike/SHA256SUMS"
    before=$(snap "$tmp/lookalike")
    build2 "$tmp/c-lookalike.out" --only modnet --input-dir "$tmp/in-good" --dist "$tmp/lookalike"
    check "a --dist of release-like files without the marker is refused, untouched" \
        sh -c 'grep -qx "exit 1" "$1" && grep -q "has no $2" "$1" && [ "$(cd "$3" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0r sha256sum)" = "$4" ]' \
        sh "$tmp/c-lookalike.out" "$marker" "$tmp/lookalike" "$before"
    cp "$tmp/foreign/notes.txt" "$d/notes.txt"
    build2 "$tmp/c-extra.out" --only modnet --input-dir "$tmp/in-good" --dist "$d"
    check "a marked --dist holding a foreign file is refused, untouched" \
        sh -c 'grep -qx "exit 1" "$1" && grep -q "notes.txt, which is not a release file" "$1" && [ -f "$2/notes.txt" ] && [ -f "$2/modnet_photographic.onnx" ]' sh "$tmp/c-extra.out" "$d"
    rm "$d/notes.txt"
    mkdir -p "$tmp/empty-dist"
    build2 "$tmp/c-empty.out" --only modnet --input-dir "$tmp/in-good" --dist "$tmp/empty-dist"
    check "an empty --dist is accepted" sh -c 'grep -qx "exit 0" "$1" && [ -f "$2/$3" ]' sh "$tmp/c-empty.out" "$tmp/empty-dist" "$marker"

    # --keep-venvs: a kept environment whose Python is not the pin is made anew.
    mkdir -p "$repo/build/venvs/verify/bin"
    cp "$tmp/fakepython" "$repo/build/venvs/verify/bin/python"
    echo 3.11.0 >"$repo/build/venvs/verify/fake-version"
    : >"$FAKE_UV_LOG"
    build2 "$tmp/c-keep.out" --only modnet --input-dir "$tmp/in-good" --dist "$d" --keep-venvs
    check "--keep-venvs: an environment with another Python is made anew" \
        sh -c 'grep -qx "exit 0" "$1" && grep -q "kept environment has Python 3.11.0, not 3.12.16: making it anew" "$1" && grep -q "^argv: --no-config venv .*/build/venvs/verify$" "$2"' \
        sh "$tmp/c-keep.out" "$FAKE_UV_LOG"
    check "... with the pinned Python" test "$(cat "$repo/build/venvs/verify/fake-version")" = 3.12.16
    : >"$FAKE_UV_LOG"
    build2 "$tmp/c-keep2.out" --only modnet --input-dir "$tmp/in-good" --dist "$d" --keep-venvs
    check "--keep-venvs: an environment with the pinned Python is reused" \
        sh -c 'grep -qx "exit 0" "$1" && ! grep -q "making it anew" "$1" && ! grep -q "^argv: --no-config venv" "$2"' sh "$tmp/c-keep2.out" "$FAKE_UV_LOG"
    rm -rf -- "$repo/build/venvs"
    check "the work directories of the copy are removed" \
        sh -c '[ -z "$(find "$1/build" -mindepth 1 -maxdepth 1 -name "work.*")" ]' sh "$repo"
else
    echo "skip: curl or unzip missing (build-models.sh with a fake uv)"
fi

if ((fails > 0)); then
    echo "$fails of $count check(s) failed"
    exit 1
fi
echo "all $count checks passed"
