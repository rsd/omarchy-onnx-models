#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Builds the release files into dist/ from the upstream originals, as
# models.toml describes them:
#
#   1. downloads each original from its pinned URL (or takes it from
#      --input-dir) into a new, empty directory and checks its SHA-256 before
#      anything reads it; a download with another SHA-256 is discarded and
#      the next URL tried, each checked against the same SHA-256, and the
#      build stops when none gives the pinned file; a file of --input-dir
#      with another SHA-256 stops the build;
#   2. converts it in a uv virtual environment pinned exactly by
#      requirements/<kind>.txt and installed from requirements/<kind>.lock
#      with every hash required, from PyPI only (MediaPipe: tf2onnx +
#      convert/fix_tconv.py;
#      PP-HumanSeg: convert/pp_static.py + paddle2onnx, and
#      convert/pp_fix_pool.py when paddle2onnx leaves an adaptive pooling
#      unresolved; MODNet: copied unchanged);
#   3. checks the result (convert/verify_model.py: onnx.checker, the input and
#      output names and shapes, a CPU smoke inference with ONNX Runtime);
#   4. a reproducible model (the default): compares the result's SHA-256 with
#      the one in models.toml; a mismatch fails the build unless
#      --accept-new-checksums is given (models.toml is never rewritten).
#      A model with reproducible = false (its conversion gives other bytes on
#      every run): the release file is a supplied reference file, from
#      --reference-dir, whose SHA-256 must be the one in models.toml (checked
#      before any conversion; a mismatch is a hard failure); the fresh
#      conversion must be equivalent to it (scripts/lib/equivalence.py, on
#      the summaries convert/verify_model.py --summary writes of both), and
#      the reference file, not the fresh one, goes to dist/. Without a
#      reference the build stops before any work, unless
#      --accept-new-checksums is given: then the fresh file is reported as a
#      mismatch and written, as for a reproducible model;
#   5. writes dist/: the model files, LICENSE-<licence>, NOTICE,
#      MANIFEST.toml and SHA256SUMS, and the marker file
#      .omarchy-onnx-models-dist (not a release file). It replaces the
#      contents of a directory only when that directory is empty or carries
#      the marker (an earlier build wrote it); any other directory is refused
#      and left as it is.
#
#   scripts/build-models.sh [options]
#     --only ID               build this model only (repeatable); dist/ then
#                             holds only these, which is not a release set
#     --input-dir DIR         take the originals from DIR (by their upstream
#                             file names) when present; still checksummed
#     --reference-dir DIR     take the reference file of each model with
#                             reproducible = false from DIR, by its release
#                             file name (the asset of the latest release);
#                             checked against the SHA-256 in models.toml
#     --accept-new-checksums  report a release file whose SHA-256 differs
#                             from models.toml and write it to dist/ anyway
#     --keep-work             keep the work directory (build/work.*)
#     --keep-venvs            keep the virtual environments in build/venvs
#                             and reuse them on the next run (one whose
#                             Python is not the pinned version is made anew)
#     --dist DIR              write the release files to DIR (default dist/):
#                             absent, empty, or written by an earlier build
#
# Network: the upstream URLs of models.toml, and PyPI and python-build-
# standalone through uv. uv runs with --no-config, --default-index
# https://pypi.org/simple and without the index variables of the environment
# (UV_INDEX_URL and the like; scripts/lib/common.sh, uv_clean). No
# credentials. The run log is build/build-models.log.
# Every Python program runs with `python -I`, from an empty directory, with
# its script and inputs passed by path.
set -euo pipefail
shopt -s nullglob

prog=${0##*/}
top=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/lib/common.sh
. "$top/scripts/lib/common.sh"

usage() {
    sed -n '/^#   scripts\/build-models.sh/,/^#     --dist/p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

only=() input_dir='' reference_dir='' accept=0 keep_work=0 keep_venvs=0 dist=$top/dist
while (($# > 0)); do
    case $1 in
        --only) (($# >= 2)) || usage; only+=("$2"); shift 2 ;;
        --input-dir) (($# >= 2)) || usage; input_dir=$(cd "$2" && pwd); shift 2 ;;
        --reference-dir) (($# >= 2)) || usage; reference_dir=$(cd "$2" && pwd); shift 2 ;;
        --accept-new-checksums) accept=1; shift ;;
        --keep-work) keep_work=1; shift ;;
        --keep-venvs) keep_venvs=1; shift ;;
        --dist) (($# >= 2)) || usage; dist=$2; shift 2 ;;
        -h | --help) usage ;;
        *) echo "$prog: unknown option: $1" >&2; usage ;;
    esac
done

die() { echo "$prog: $*" >&2; exit 1; }
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

for tool in uv curl unzip sha256sum python3 git; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done
python3 -I -c 'import tomllib' 2>/dev/null || die "python3 must be 3.11 or newer (tomllib)"

# check_dist: the output directory may be written only when it is absent,
# empty, or carries the marker an earlier build wrote, and then only when it
# holds nothing but release files: a --dist pointing at the wrong place is
# refused and left untouched. Checked before any work and again before
# writing.
marker=.omarchy-onnx-models-dist
check_dist() {
    local path contents
    [[ ! -L $dist ]] || die "$dist is a symbolic link; not writing to it"
    [[ ! -e $dist || -d $dist ]] || die "$dist is not a directory; not writing to it"
    [[ -d $dist ]] || return 0
    contents=("$dist"/* "$dist"/.[!.]* "$dist"/..?*)
    ((${#contents[@]} > 0)) || return 0
    [[ -f $dist/$marker && ! -L $dist/$marker ]] ||
        die "$dist is not empty and has no $marker (it was not written by this build); not replacing its contents"
    for path in "${contents[@]}"; do
        case ${path##*/} in
            "$marker" | *.onnx | MANIFEST.toml | SHA256SUMS | NOTICE | LICENSE-*) [[ -f $path && ! -L $path ]] ||
                die "$dist holds $path, which is not a release file; not replacing it" ;;
            *) die "$dist holds $path, which is not a release file; not replacing it" ;;
        esac
    done
}

table=$top/models.toml
models() { python3 -I "$top/scripts/lib/models.py" --models "$table" "$@"; }
models check --repo "$top" >/dev/null || die "models.toml is inconsistent (scripts/lib/models.py check --repo .)"

mapfile -t all_ids < <(models ids)
if ((${#only[@]} > 0)); then
    for id in "${only[@]}"; do
        models get "$id" file >/dev/null || die "unknown model id: $id"
    done
    ids=("${only[@]}")
else
    ids=("${all_ids[@]}")
fi
check_dist
declare -A need_kind=()
for id in "${ids[@]}"; do
    need_kind[$(models get "$id" kind)]=1
done

mkdir -p "$top/build"
work=$(mktemp -d "$top/build/work.XXXXXX")
if ((keep_venvs)); then venvs=$top/build/venvs; else venvs=$work/venvs; fi
cleanup() {
    local status=$?
    if ((keep_work)); then
        log "work directory kept: $work"
    else
        rm -rf -- "$work"
    fi
    exit "$status"
}
trap cleanup EXIT
exec > >(tee "$top/build/build-models.log") 2>&1

facts=$work/facts.tsv
: >"$facts"
empty=$work/cwd
mkdir -p "$empty" "$work/out"

# Runs a command from the empty directory (no download, extract or source
# directory is ever the current one).
in_empty() { (cd "$empty" && "$@"); }

# python_version <interpreter>: its version (x.y.z), or nothing when it does
# not run.
python_version() {
    in_empty "$1" -I -c 'import platform; print(platform.python_version())' 2>/dev/null || true
}

# make_venv <name>: the environment of requirements/<name>.txt, exactly,
# installed from requirements/<name>.lock with every hash required (uv pip
# sync --require-hashes), and its facts.
make_venv() {
    local name=$1 version=${env_python[$1]} dir=$venvs/$1 req=$top/requirements/$1.txt
    local lock=$top/requirements/$1.lock frozen pinned got
    log "environment $name: Python $version, $lock"
    [[ -f $lock ]] || die "no $lock (scripts/lock-requirements.sh)"
    # A kept environment (--keep-venvs) is reused only when its interpreter
    # is the pinned one; otherwise it is made anew.
    if [[ -e $dir ]]; then
        got=$(python_version "$dir/bin/python")
        if [[ $got != "$version" ]]; then
            log "environment $name: kept environment has Python ${got:-(none)}, not $version: making it anew"
            rm -rf -- "$dir"
        fi
    fi
    if [[ ! -x $dir/bin/python ]]; then
        uv_clean venv --quiet --python "$version" --python-preference only-managed "$dir"
    fi
    uv_clean pip sync --quiet --strict --require-hashes --default-index "$pypi_index" \
        --python "$dir/bin/python" "$lock"
    frozen=$(uv_clean pip freeze --quiet --python "$dir/bin/python" | LC_ALL=C sort)
    pinned=$(grep -vE '^[[:space:]]*(#|$)' "$req" | LC_ALL=C sort)
    [[ $frozen == "$pinned" ]] ||
        die "environment $name does not match $req: $(diff <(printf '%s\n' "$pinned") <(printf '%s\n' "$frozen") || true)"
    got=$(python_version "$dir/bin/python")
    [[ $got == "$version" ]] || die "environment $name: Python ${got:-(none)}, not $version"
    fact "$facts" "python.$name" "$got"
    fact "$facts" "freeze.$name" "$(tr '\n' ' ' <<<"$frozen" | sed 's/ $//')"
}

log "models: ${ids[*]}"
log "work directory: $work"

# The reference files of the models that are not byte-reproducible, checked
# against models.toml before any environment or conversion.
declare -A reference=()
for id in "${ids[@]}"; do
    [[ $(models reproducible "$id") == no ]] || continue
    file=$(models get "$id" file)
    want=$(models get "$id" sha256)
    status=1
    if [[ -n $reference_dir ]]; then
        status=0
        reuse_verified "$reference_dir" "$work/references/$id" "$file" "$want" || status=$?
        ((status != 3)) ||
            die "$id: the reference $reference_dir/$file is not the release file: its SHA-256 must be $want (models.toml)"
        ((status != 2)) || die "$id: could not copy the reference $reference_dir/$file"
    fi
    if ((status == 0)); then
        reference[$id]=$FETCHED_PATH
        log "$id: reference $file verified ($want) from $reference_dir"
    elif ((accept)); then
        log "WARNING: $id is not byte-reproducible and no reference was supplied: the fresh conversion will be reported as a mismatch and written to dist/ (--accept-new-checksums)"
    else
        die "$id: its conversion is not byte-reproducible (models.toml: reproducible = false), so the release file is a reference file: give --reference-dir DIR with $file (SHA-256 $want), the asset of the latest release (docs/release.md, Reproducibility); --accept-new-checksums builds the fresh file instead and reports it"
    fi
done
[[ -z ${need_kind[tflite]:-} ]] || make_venv tflite
[[ -z ${need_kind[paddle]:-} ]] || make_venv paddle
make_venv verify
tfpy=$venvs/tflite/bin/python ppy=$venvs/paddle/bin/python vpy=$venvs/verify/bin/python

# convert_tflite <id> <input> <conversion dir> <output>
convert_tflite() {
    local id=$1 in=$2 dir=$3 out=$4 opset name run
    opset=$(models get "$id" tf2onnx_opset)
    # tf2onnx writes "converted from <the --tflite argument>" into the model's
    # doc_string: pass the bare file name, so that no build path ends up in
    # the release file. It runs in a new directory holding only a copy of the
    # verified original (-I keeps that directory off sys.path).
    name=${in##*/}
    run=$dir/tf2onnx-run
    mkdir -p "$run"
    cp -- "$in" "$run/$name"
    (cd "$run" && "$tfpy" -I -m tf2onnx.convert --tflite "$name" --output "$dir/tf2onnx.onnx" --opset "$opset")
    in_empty "$tfpy" -I "$top/convert/fix_tconv.py" "$dir/tf2onnx.onnx" "$out"
    fact "$facts" "$id.steps" "tf2onnx.convert --tflite --opset $opset; convert/fix_tconv.py (Convolution2DTransposeBias -> Transpose + ConvTranspose + Transpose)"
}

# convert_paddle <id> <input zip> <conversion dir> <output>
convert_paddle() {
    local id=$1 in=$2 dir=$3 out=$4 sub h w src static needs steps
    sub=$(models get "$id" paddle_model_dir)
    mapfile -t shape < <(models get "$id" input.shape)
    h=${shape[2]} w=${shape[3]}
    safe_unzip "$in" "$dir/extract"
    src=$dir/extract/$sub
    [[ -f $src/model.pdmodel && -f $src/model.pdiparams ]] ||
        die "$id: $sub/model.pdmodel or model.pdiparams missing from the archive"
    static=$dir/static
    in_empty "$ppy" -I "$top/convert/pp_static.py" "$src" "$static" "$h" "$w"
    in_empty "$ppy" -I -c 'import sys; from paddle2onnx.command import main; sys.argv[0] = "paddle2onnx"; sys.exit(main())' \
        --model_dir "$static" --model_filename model.pdmodel --params_filename model.pdiparams \
        --opset_version 13 --save_file "$dir/paddle2onnx.onnx"
    needs=$(in_empty "$ppy" -I "$top/convert/pp_has_adaptive_pool.py" "$dir/paddle2onnx.onnx")
    steps="convert/pp_static.py 1x3x${h}x${w}; paddle2onnx --opset_version 13"
    case $needs in
        yes)
            log "$id: paddle2onnx left an adaptive AveragePool (kernel -1): applying convert/pp_fix_pool.py"
            in_empty "$ppy" -I "$top/convert/pp_fix_pool.py" "$static" "$dir/paddle2onnx.onnx" "$out" "$h" "$w"
            fact "$facts" "$id.pool_fix" yes
            steps+="; convert/pp_fix_pool.py (adaptive AveragePool kernel -1 resolved)"
            ;;
        no)
            log "$id: no unresolved adaptive pooling: convert/pp_fix_pool.py not needed"
            cp -- "$dir/paddle2onnx.onnx" "$out"
            fact "$facts" "$id.pool_fix" no
            steps+="; convert/pp_fix_pool.py not needed"
            ;;
        *) die "$id: pp_has_adaptive_pool.py printed: $needs" ;;
    esac
    fact "$facts" "$id.steps" "$steps"
}

mismatches=()
for id in "${ids[@]}"; do
    file=$(models get "$id" file)
    kind=$(models get "$id" kind)
    input_file=$(models get "$id" input_file)
    input_sha=$(models get "$id" input_sha256)
    want=$(models get "$id" sha256)
    mapfile -t urls < <(models get "$id" input_urls)
    log "== $id ($file, $kind)"

    status=1
    if [[ -n $input_dir ]]; then
        status=0
        reuse_verified "$input_dir" "$work/inputs/$id" "$input_file" "$input_sha" || status=$?
        ((status != 3)) || die "$id: $input_dir/$input_file has the wrong checksum (models.toml: $input_sha); dist/ untouched"
        ((status != 2)) || die "$id: could not copy $input_dir/$input_file; dist/ untouched"
    fi
    if ((status != 0)); then
        status=0
        fetch_verified "$work/inputs/$id" "$input_file" "$input_sha" "${urls[@]}" || status=$?
        ((status != 3)) || die "$id: no source gave $input_file with the SHA-256 of models.toml ($input_sha); at least one gave another file"
        ((status == 0)) || die "$id: could not download $input_file"
    fi
    log "$id: input $input_file verified ($input_sha) from $FETCHED_URL"
    # A local copy is recorded without its path: the manifest is published.
    if [[ $FETCHED_URL == file://* ]]; then
        fact "$facts" "$id.fetched_url" "a local copy (--input-dir), SHA-256 checked"
    else
        fact "$facts" "$id.fetched_url" "$FETCHED_URL"
    fi

    dir=$work/convert/$id
    out=$work/out/$file
    mkdir -p "$dir"
    case $kind in
        tflite) convert_tflite "$id" "$FETCHED_PATH" "$dir" "$out" ;;
        paddle) convert_paddle "$id" "$FETCHED_PATH" "$dir" "$out" ;;
        copy)
            cp -- "$FETCHED_PATH" "$out"
            fact "$facts" "$id.steps" "copied unchanged"
            ;;
        *) die "$id: unknown kind $kind" ;;
    esac
    rm -rf -- "$dir" "$work/inputs/$id"

    if [[ -n ${reference[$id]:-} ]]; then
        ref=${reference[$id]}
        eq=$work/equivalence/$id
        mkdir -p "$eq"
        log "$id: fresh conversion $(sha256_of "$out") ($(stat -c %s "$out") bytes); checking it against the reference"
        in_empty "$vpy" -I "$top/convert/verify_model.py" "$table" "$id" "$out" --summary "$eq/fresh.json"
        in_empty "$vpy" -I "$top/convert/verify_model.py" "$table" "$id" "$ref" --summary "$eq/reference.json"
        in_empty python3 -I "$top/scripts/lib/equivalence.py" "$eq/reference.json" "$eq/fresh.json" \
            --tolerance "$(models get "$id" equivalence_tolerance)" --facts "$facts" --id "$id" ||
            die "$id: the fresh conversion is not equivalent to the reference $file; dist/ untouched"
        cp -- "$ref" "$out"
        rm -rf -- "$eq"
        fact "$facts" "$id.provenance" "reference conversion, verified equivalent"
        fact "$facts" "$id.reference_source" "supplied with --reference-dir, SHA-256 checked against models.toml"
        log "$id: equivalent; the release file is the reference"
    else
        in_empty "$vpy" -I "$top/convert/verify_model.py" "$table" "$id" "$out"
    fi

    got=$(sha256_of "$out")
    if [[ $got == "$want" ]]; then
        log "$id: $file sha256 $got matches models.toml ($(stat -c %s "$out") bytes)"
        [[ -n ${reference[$id]:-} ]] ||
            fact "$facts" "$id.provenance" "built from the original; byte-identical to models.toml"
    else
        log "$id: $file sha256 MISMATCH: models.toml $want, built $got ($(stat -c %s "$out") bytes)"
        mismatches+=("$id")
        fact "$facts" "$id.provenance" "built from the original; SHA-256 differs from models.toml (--accept-new-checksums)"
    fi
done

if ((${#mismatches[@]} > 0)); then
    if ((accept)); then
        log "WARNING: new checksums accepted for: ${mismatches[*]} (models.toml unchanged; update it and the docs by hand if intended)"
    else
        die "checksum mismatch for: ${mismatches[*]}; dist/ untouched (--accept-new-checksums to write them anyway)"
    fi
fi

stage=$work/dist
mkdir -p "$stage"
cp -- "$work/out/"*.onnx "$stage/"
for id in "${ids[@]}"; do
    lic=$(models licence-file "$id")
    [[ -f $stage/$lic ]] || cp -- "$top/licenses/$id/LICENSE" "$stage/$lic"
done
cp -- "$top/NOTICE" "$stage/NOTICE"

revision=unknown
if rev=$(git -C "$top" rev-parse -q --verify HEAD 2>/dev/null); then
    revision=$rev
    # A modified tracked file or an untracked one (ignored files aside) is a
    # change the commit does not hold.
    [[ -z $(git -C "$top" status --porcelain --untracked-files=normal 2>/dev/null) ]] || revision+="-modified"
fi
fact "$facts" project omarchy-onnx-models
fact "$facts" source_revision "$revision"
models manifest "$stage" "$facts"
write_sha256sums "$stage"
check_sha256sums "$stage"

check_dist
mkdir -p -- "$dist"
# The marker first: a run interrupted while copying leaves a directory the
# next run may replace.
printf '%s\n' "Written by omarchy-onnx-models scripts/build-models.sh; every build replaces this directory's contents. Not a release file." >"$dist/$marker"
for path in "$dist"/*; do rm -f -- "$path"; done
cp -p -- "$stage/"* "$dist/"
check_sha256sums "$dist"
log "work directory size before removal: $(du -sh "$work" | cut -f1)"
log "dist: $dist"
(cd "$dist" && ls -l)
((${#only[@]} == 0)) || log "NOTE: --only given: $dist is not a complete release set"
log "done"
