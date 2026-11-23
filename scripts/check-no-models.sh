#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# The guard: fails when a file that must never be committed is about to be.
# This repository holds the recipe only; the model files are release assets,
# built into dist/. No model, weight file, archive, binary or build output may
# enter the history.
#
#   check-no-models.sh [--staged]        # the index (default; pre-commit and
#                                        # pre-merge-commit hooks)
#   check-no-models.sh --all             # every tracked and untracked, not
#                                        # ignored file of the work tree
#   check-no-models.sh --range REV...    # every file added or modified by the
#                                        # commits `git rev-list REV...` lists
#                                        # (pre-push hook), e.g.
#                                        #   --range origin/main..main
#                                        #   --range main --not --remotes=origin
#
# --all looks at the work tree only, not at the history; --range covers
# commits. Hooks can be bypassed with --no-verify: the guard is a safety net,
# not an access control.
#
# Every added, modified or type-changed entry is checked (a rename counts as
# an addition; only deletions are skipped). An entry fails when:
#   - its path matches a model, weight, archive or binary pattern: ONNX and
#     ONNX Runtime (.onnx, .ort), TensorFlow and TFLite (.tflite, .lite, .pb,
#     .pbtxt, .h5, .keras), Paddle (.pdmodel, .pdiparams, .pdparams, .pdopt),
#     PyTorch and others (.pt, .pth, .ckpt, .safetensors, .bin, .npy, .npz,
#     .pkl, .engine, .trt, .plan, .mlmodel), archives (.zip, .tar*, .tgz,
#     .gz, .xz, .zst, .bz2, .7z, .whl), libraries (.so, .a, .o), PDFs, logs;
#     or anything under dist/ or build/ (in any letter case), a virtual
#     environment or __pycache__/;
#   - it is a submodule (gitlink), or, in --all, a nested repository;
#   - it is a symbolic link whose target is absolute or leaves the repository;
#   - its content is larger than 1 MiB, starts with a binary or archive magic
#     number (ELF, gzip, zip, PDF, xz, zstd, bzip2, 7z, ar, POSIX tar, a TFLite
#     flatbuffer), or has a NUL byte in its first 8 KiB (ONNX and Paddle
#     protobufs, weights).
# The licence texts and notices of this repository are plain text and pass.
# Staged and committed content is read from the object database with git
# cat-file (read-only), so what is checked is what would be committed or
# pushed. Exit status: 0 clean, 1 offending files, 2 usage or git error.
set -euo pipefail

prog=${0##*/}
max_size=$((1024 * 1024))

usage() {
    echo "usage: $prog [--staged | --all | --range REV...]" >&2
    exit 2
}

mode=staged range=()
if (($# > 0)); then
    case $1 in
        --staged) (($# == 1)) || usage; mode=staged ;;
        --all) (($# == 1)) || usage; mode=all ;;
        --range) (($# >= 2)) || usage; mode=range; shift; range=("$@") ;;
        *) usage ;;
    esac
fi

top=$(git rev-parse --show-toplevel 2>/dev/null) ||
    { echo "$prog: not inside a git work tree" >&2; exit 2; }
cd "$top"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# Prints the reason when the path is forbidden, nothing otherwise. A path may
# hold any byte but NUL (spaces, newlines): it is matched with patterns and
# parameter expansion only, never split with read.
path_reason() {
    local path=$1 base lcbase
    base=${path##*/}
    lcbase=${base,,}

    # Build output and environments (also in .gitignore). dist/ and build/
    # count at the top only, in any letter case (Dist/, BUILD/: one directory
    # on a case-insensitive file system); the others anywhere.
    case ${path,,} in
        dist/* | build/*) echo "build output (${path%%/*}/)"; return ;;
    esac
    case /$path/ in
        */__pycache__/* | */.venv/* | */venv/* | */venvs/* | */.pytest_cache/*)
            echo "build output or virtual environment"; return ;;
    esac

    # Model, weight, archive and binary extensions (case-insensitive).
    case $lcbase in
        *.onnx | *.ort) echo "ONNX model"; return ;;
        *.tflite | *.lite) echo "TensorFlow Lite model"; return ;;
        *.pb | *.pbtxt | *.h5 | *.keras) echo "TensorFlow or Keras model"; return ;;
        *.pdmodel | *.pdiparams | *.pdparams | *.pdopt) echo "Paddle model or weights"; return ;;
        *.pt | *.pth | *.ckpt | *.safetensors) echo "PyTorch or checkpoint weights"; return ;;
        *.bin | *.npy | *.npz | *.pkl) echo "binary data or weights"; return ;;
        *.engine | *.trt | *.plan | *.mlmodel) echo "compiled model"; return ;;
        *.whl) echo "Python wheel"; return ;;
        *.zip | *.tar | *.tar.* | *.tgz | *.gz | *.xz | *.zst | *.bz2 | *.7z) echo "archive"; return ;;
        *.so | *.so.* | *.a | *.o | *.dll) echo "library or object file"; return ;;
        *.pyc) echo "Python bytecode"; return ;;
        *.pdf) echo "PDF document"; return ;;
        *.log) echo "log file"; return ;;
    esac
    case /${path,,}/ in
        */*.mlpackage/*) echo "compiled model"; return ;;
    esac
}

# Prints the reason when a symbolic link at <path> pointing to <target> is
# forbidden: an absolute target, or one that leaves the repository.
link_reason() {
    local path=$1 target=$2 rest component depth=0
    [[ -n $target ]] || return 0
    if [[ $target == /* ]]; then
        echo "symbolic link to an absolute path"
        return
    fi
    # The link's directory, then the target, resolved lexically.
    rest=''
    [[ $path != */* ]] || rest=${path%/*}/
    rest+=$target
    while [[ -n $rest ]]; do
        component=${rest%%/*}
        case $component in
            '' | .) ;;
            ..) depth=$((depth - 1)) ;;
            *) depth=$((depth + 1)) ;;
        esac
        if ((depth < 0)); then
            echo "symbolic link leaving the repository"
            return
        fi
        if [[ $rest == */* ]]; then rest=${rest#*/}; else rest=''; fi
    done
}

hex() { od -An -v -tx1 | tr -d ' \n'; }

# Prints the reason when the content of <file> (a regular file of <size>
# bytes) is forbidden, nothing otherwise.
content_reason() {
    local file=$1 size=$2 magic
    if ((size > max_size)); then
        echo "larger than 1 MiB ($size bytes)"
        return
    fi
    magic=$(head -c 8 -- "$file" | hex)
    case $magic in
        7f454c46*) echo "ELF binary"; return ;;
        1f8b*) echo "gzip data"; return ;;
        504b0304* | 504b0506*) echo "zip data"; return ;;
        25504446*) echo "PDF document"; return ;;
        fd377a585a*) echo "xz data"; return ;;
        28b52ffd*) echo "zstd data"; return ;;
        425a68*) echo "bzip2 data"; return ;;
        377abcaf271c*) echo "7z data"; return ;;
        213c617263683e0a*) echo "ar archive"; return ;;
        ????????54464c33*) echo "TensorFlow Lite flatbuffer"; return ;;
    esac
    # POSIX tar: "ustar" at offset 257. (head may stop tail early.)
    if ((size >= 262)) && [[ $({ tail -c +258 -- "$file" || true; } | head -c 5 | hex) == 7573746172 ]]; then
        echo "tar archive"
        return
    fi
    if (($(head -c 8192 -- "$file" | tr -dc '\000' | wc -c) > 0)); then
        echo "binary data (a NUL byte in the first 8 KiB)"
        return
    fi
}

failures=0
report() {
    local shown=$1
    [[ $shown != *[[:cntrl:]]* ]] || printf -v shown '%q' "$1"
    printf '%s: %s\n' "$shown" "$2"
    failures=$((failures + 1))
}

# check_object <path> <mode> <object id>: an index or tree entry.
check_object() {
    local path=$1 objmode=$2 oid=$3 reason size
    reason=$(path_reason "$path")
    if [[ -z $reason ]]; then
        case $objmode in
            160000) reason="submodule (gitlink)" ;;
            120000) reason=$(link_reason "$path" "$(git cat-file blob "$oid")") ;;
            100644 | 100755)
                size=$(git cat-file -s "$oid")
                if ((size > max_size)); then
                    reason="larger than 1 MiB ($size bytes)"
                else
                    git cat-file blob "$oid" >"$tmp/blob"
                    reason=$(content_reason "$tmp/blob" "$size")
                fi
                ;;
            *) reason="unexpected entry (mode $objmode)" ;;
        esac
    fi
    [[ -z $reason ]] || report "$path" "$reason"
}

# Reads `git diff --raw -z --no-abbrev --no-renames` records on stdin and
# checks each entry once.
check_raw() {
    local meta path dstmode dstoid
    local -A seen=()
    while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
        read -r _ dstmode _ dstoid _ <<<"${meta#:}"
        # An unmerged entry has no object yet (git refuses to commit it).
        [[ $dstmode != 000000 ]] || continue
        [[ -z ${seen[$dstmode:$dstoid:$path]:-} ]] || continue
        seen[$dstmode:$dstoid:$path]=1
        check_object "$path" "$dstmode" "$dstoid"
    done
}

check_staged() {
    # Without a HEAD (no commit yet) git compares with the empty tree. In a
    # hook, GIT_INDEX_FILE names the index being committed (commit -a,
    # commit <path>).
    git diff --cached --raw -z --no-abbrev --no-renames --diff-filter=d \
        --ignore-submodules=none >"$tmp/raw" ||
        { echo "$prog: git diff --cached failed" >&2; exit 2; }
    check_raw <"$tmp/raw"
}

check_range() {
    git rev-list "${range[@]}" -- >"$tmp/commits" ||
        { echo "$prog: git rev-list ${range[*]} failed" >&2; exit 2; }
    # -m compares a merge with each of its parents, so what the merge itself
    # brings (a conflict resolution) is checked too.
    git diff-tree --stdin -r -m --root --no-commit-id --raw -z --no-abbrev \
        --no-renames --diff-filter=d --ignore-submodules=none <"$tmp/commits" >"$tmp/raw" ||
        { echo "$prog: git diff-tree failed" >&2; exit 2; }
    check_raw <"$tmp/raw"
}

check_all() {
    local path reason
    git ls-files -z -co --exclude-standard >"$tmp/files" ||
        { echo "$prog: git ls-files failed" >&2; exit 2; }
    while IFS= read -r -d '' path; do
        # An untracked nested repository is listed as dir/.
        path=${path%/}
        reason=$(path_reason "$path")
        if [[ -z $reason ]]; then
            if [[ -L $path ]]; then
                reason=$(link_reason "$path" "$(readlink -- "$path")")
            elif [[ -d $path ]]; then
                reason="submodule or nested repository"
            elif [[ -f $path ]]; then
                reason=$(content_reason "$path" "$(stat -c %s -- "$path")")
            fi
            # Anything else is a tracked file deleted from the work tree.
        fi
        [[ -z $reason ]] || report "$path" "$reason"
    done < <(sort -zu "$tmp/files")
}

case $mode in
    staged) check_staged ;;
    all) check_all ;;
    range) check_range ;;
esac

if ((failures > 0)); then
    echo "This repository holds the recipe only; model files, archives and binaries must never be committed (docs/maintainers.md, \"Keep models out of the history\")." >&2
    exit 1
fi
echo "ok: no model, archive or binary files ($mode)"
