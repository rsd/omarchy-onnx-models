#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Prints the .SRCINFO of packaging/arch/PKGBUILD, the one the AUR shows, or
# stages the recipe for an AUR push.
#
#   scripts/srcinfo.sh             # prints it
#   scripts/srcinfo.sh --aur DIR   # writes PKGBUILD, a freshly generated
#                                  # .SRCINFO and LICENSE (0BSD) into DIR, the
#                                  # top of a git work tree (the AUR repository
#                                  # ssh://aur@aur.archlinux.org/omarchy-onnx-models.git)
#   scripts/srcinfo.sh --check DIR # fails, with a diff, when DIR's files are
#                                  # not those --aur would write
#
# The .SRCINFO is made by `makepkg --printsrcinfo` on a copy of the PKGBUILD
# alone in an empty directory under mktemp, with an empty environment apart
# from PATH, an empty HOME and LC_ALL=C: nothing is written next to the recipe
# and no variable of the caller can change it. The AUR PKGBUILD is the one of
# this repository, unchanged. --aur commits nothing: DIR's git index is left
# to the maintainer. DIR may hold only .git and the three files.
# Exit status: 0 done (or up to date), 1 refused or stale, 2 usage or makepkg
# error.
set -euo pipefail

prog=${0##*/}
top=$(cd "$(dirname "$0")/.." && pwd)
pkgbuild=$top/packaging/arch/PKGBUILD

usage() {
    echo "usage: $prog [--aur DIR | --check DIR]" >&2
    exit 2
}

mode=print aur=''
case ${#} in
    0) ;;
    2)
        case $1 in
            --aur | --check) mode=${1#--} aur=$2 ;;
            *) usage ;;
        esac
        ;;
    *) usage ;;
esac

command -v makepkg >/dev/null 2>&1 || { echo "$prog: makepkg not found" >&2; exit 2; }
[[ -f $pkgbuild ]] || { echo "$prog: $pkgbuild does not exist" >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# srcinfo <dir>: the .SRCINFO of <dir>/PKGBUILD, alone in an empty directory,
# in an empty environment.
srcinfo() {
    local work
    work=$(mktemp -d "$tmp/srcinfo.XXXXXX")
    mkdir "$work/recipe" "$work/home"
    cp -- "$1/PKGBUILD" "$work/recipe/PKGBUILD"
    (cd "$work/recipe" && env -i PATH="$PATH" HOME="$work/home" LC_ALL=C makepkg --printsrcinfo) ||
        { echo "$prog: makepkg --printsrcinfo failed" >&2; exit 2; }
}

cp -- "$pkgbuild" "$tmp/PKGBUILD"
srcinfo "$tmp" >"$tmp/.SRCINFO"

cat >"$tmp/LICENSE" <<'EOF'
Copyright (c) 2026 Raul Dias <raul@dias.com.br>

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY
AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
PERFORMANCE OF THIS SOFTWARE.
EOF

files=(PKGBUILD .SRCINFO LICENSE)

# aur_dir: the absolute path of $aur, which must be the top of a git work
# tree, not a directory inside one: an AUR repository has the files at its top.
aur_dir() {
    local dir git_top
    if ! dir=$(cd -- "$aur" 2>/dev/null && pwd -P) ||
        ! git_top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) ||
        [[ $(cd -- "$git_top" && pwd -P) != "$dir" ]]; then
        echo "$prog: $aur is not the top of a git work tree (git init, or git clone ssh://aur@aur.archlinux.org/omarchy-onnx-models.git)" >&2
        exit 1
    fi
    printf '%s\n' "$dir"
}

# extra <dir>: fails when <dir> holds anything but .git and the files: an AUR
# repository holds exactly what is pushed.
extra() {
    local f found=0
    while IFS= read -r -d '' f; do
        f=${f##*/}
        case $f in .git | PKGBUILD | .SRCINFO | LICENSE) continue ;; esac
        echo "$prog: $1/$f is not part of the AUR package" >&2
        found=1
    done < <(find "$1" -mindepth 1 -maxdepth 1 -print0)
    if ((found)); then
        echo "$prog: remove the files above from $1 first" >&2
        exit 1
    fi
}

case $mode in
    print) cat "$tmp/.SRCINFO" ;;
    aur)
        dir=$(aur_dir)
        extra "$dir"
        for f in "${files[@]}"; do
            cp -- "$tmp/$f" "$dir/.$f.tmp"
            mv -f -- "$dir/.$f.tmp" "$dir/$f"
        done
        # The .SRCINFO written is that of the PKGBUILD written.
        srcinfo "$dir" >"$tmp/again"
        cmp -s "$tmp/again" "$dir/.SRCINFO" || { echo "$prog: $dir/.SRCINFO is not that of $dir/PKGBUILD" >&2; exit 1; }
        echo "wrote ${files[*]} into $dir; review, commit and push there"
        ;;
    check)
        dir=$(aur_dir)
        stale=0
        for f in "${files[@]}"; do
            if [[ ! -f $dir/$f ]]; then
                echo "$prog: $dir/$f does not exist" >&2
                stale=1
            elif ! diff -u --label "$dir/$f" --label generated "$dir/$f" "$tmp/$f"; then
                stale=1
            fi
        done
        extra "$dir"
        if ((stale)); then
            echo "$prog: $dir is stale: run $prog --aur $aur" >&2
            exit 1
        fi
        echo "$dir is up to date"
        ;;
esac
