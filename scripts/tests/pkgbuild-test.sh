#!/usr/bin/env bash
# shellcheck disable=SC2016 # patterns and PKGBUILD text in single quotes, on purpose
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Test of the Arch packaging recipe (packaging/arch/PKGBUILD): it must stay
# in step with the model table (models.toml) and the licence files: one
# package per model (omarchy-onnx-model-<id>), the same ids in the same
# order, the same release file names, the same SHA-256 of every file, the
# SHA-256 of every licence and notice of licenses/, the release tag in the
# source URLs, and a pkgver of the form x.y.z. The checks must catch each
# kind of defect, on altered copies of the PKGBUILD under mktemp.
# There is no machine-readable record of the current release version in the
# repository (docs/release.md names the tag only as an example), so pkgver is
# checked for its form, not against a tag. The PKGBUILD is plain bash; it is
# sourced in a subshell to read its arrays (nothing is built or downloaded).
# System python3 (3.11 or newer), standard library only, no network.
# Usage: scripts/tests/pkgbuild-test.sh. Exits non-zero on any failure.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
top=$(cd "$here/../.." && pwd)
models_py=$top/scripts/lib/models.py
models=$top/models.toml

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fails=0 count=0
ok() { count=$((count + 1)); echo "ok   $1"; }
fail() { count=$((count + 1)); echo "FAIL $1"; fails=$((fails + 1)); }

# The PKGBUILD's licence and notice sources are pinned to the tag v$pkgver, so
# their SHA-256 is read from that tag when it exists locally (nothing is
# fetched); otherwise (a clone without tags, a release being prepared) from the
# working tree.
lic_sha() { # <pkgver> <id> <LICENSE|NOTICE>
    if git -C "$top" rev-parse -q --verify "refs/tags/v$1" >/dev/null 2>&1; then
        git -C "$top" show "v$1:licenses/$2/$3" | sha256sum | cut -d' ' -f1
    else
        sha256sum "$top/licenses/$2/$3" | cut -d' ' -f1
    fi
}

py() { python3 -I "$models_py" --models "$models" "$@"; }

# check_pkgbuild <PKGBUILD>: prints one line per defect; no output = in step.
check_pkgbuild() {
    local pkgbuild=$1 facts
    # shellcheck disable=SC2154 # the variables come from the sourced PKGBUILD
    facts=$(
        # shellcheck disable=SC1090 # the file under test
        source "$pkgbuild"
        echo "pkgbase=$pkgbase"
        echo "pkgver=$pkgver"
        echo "arch=${arch[*]}"
        echo "url=$url"
        echo "pkgname=${pkgname[*]}"
        echo "source=${source[*]}"
        echo "sha256sums=${sha256sums[*]}"
        echo "ids=${_ids[*]}"
        echo "files=${_files[*]}"
        for n in "${pkgname[@]}"; do
            if declare -F "package_$n" >/dev/null; then echo "function=$n"; else echo "nofunction=$n"; fi
        done
    ) || { echo "the PKGBUILD cannot be sourced"; return 0; }
    local -A f=()
    local line key
    while IFS= read -r line; do
        key=${line%%=*}
        case $key in
            function | nofunction) f[$key]+="${line#*=} " ;;
            *) f[$key]=${line#*=} ;;
        esac
    done <<<"$facts"

    local -a ids want_files want_sums
    mapfile -t ids < <(py ids)
    local id
    for id in "${ids[@]}"; do
        want_files+=("$(py get "$id" file)")
        want_sums+=("$(py get "$id" sha256)")
    done

    [[ ${f[pkgbase]} == omarchy-onnx-models ]] || echo "pkgbase is '${f[pkgbase]}', want omarchy-onnx-models"
    [[ ${f[pkgver]} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || echo "pkgver '${f[pkgver]}' is not x.y.z"
    [[ ${f[arch]} == any ]] || echo "arch is '${f[arch]}', want any"
    [[ ${f[url]} == https://github.com/rsd/omarchy-onnx-models ]] || echo "url is '${f[url]}'"
    [[ ${f[ids]} == "${ids[*]}" ]] || echo "ids: '${f[ids]}', models.toml has '${ids[*]}'"
    [[ ${f[files]} == "${want_files[*]}" ]] || echo "files: '${f[files]}', models.toml has '${want_files[*]}'"
    local want_names=()
    for id in "${ids[@]}"; do want_names+=("omarchy-onnx-model-$id"); done
    [[ ${f[pkgname]} == "${want_names[*]}" ]] || echo "pkgname: '${f[pkgname]}', want '${want_names[*]}'"
    [[ -z ${f[nofunction]:-} ]] || echo "no package_ function for: ${f[nofunction]}"

    # source and sha256sums, per model in table order: the release file, the
    # licence, the notice.
    local -a src sums want_src want_sum_list
    read -ra src <<<"${f[source]}"
    read -ra sums <<<"${f[sha256sums]}"
    local rel="${f[url]}/releases/download/v${f[pkgver]}"
    local tree="https://raw.githubusercontent.com/rsd/omarchy-onnx-models/v${f[pkgver]}/licenses"
    local i
    for i in "${!ids[@]}"; do
        id=${ids[i]}
        want_src+=("$rel/${want_files[i]}" "$id-LICENSE::$tree/$id/LICENSE" "$id-NOTICE::$tree/$id/NOTICE")
        want_sum_list+=("${want_sums[i]}" "$(lic_sha "${f[pkgver]}" "$id" LICENSE)" "$(lic_sha "${f[pkgver]}" "$id" NOTICE)")
    done
    [[ ${src[*]} == "${want_src[*]}" ]] || echo "source: '${src[*]}', want '${want_src[*]}'"
    [[ ${sums[*]} == "${want_sum_list[*]}" ]] || echo "sha256sums: '${sums[*]}', want '${want_sum_list[*]}'"
    # Every package declares its licence and a description, and installs its
    # file into the shared directory with its licence and notice.
    for id in "${ids[@]}"; do
        grep -qE "^package_omarchy-onnx-model-$id\(\)" "$pkgbuild" || echo "no package_omarchy-onnx-model-$id()"
    done
    local nlic ndesc
    nlic=$(grep -cE "^    license=\('Apache-2\.0'\)$" "$pkgbuild" || true)
    ndesc=$(grep -cE "^    pkgdesc='.+'$" "$pkgbuild" || true)
    ((nlic == ${#ids[@]})) || echo "$nlic license=('Apache-2.0') lines, want ${#ids[@]}"
    ((ndesc == ${#ids[@]})) || echo "$ndesc pkgdesc lines, want ${#ids[@]}"
    grep -qF '/usr/share/omarchy-onnx-models/' "$pkgbuild" || echo "the install directory /usr/share/omarchy-onnx-models/ is not named"
    grep -qF '/usr/share/licenses/$pkgname/LICENSE' "$pkgbuild" || echo "the licence is not installed into /usr/share/licenses/\$pkgname/"
    grep -qF '/usr/share/licenses/$pkgname/NOTICE' "$pkgbuild" || echo "the notice is not installed into /usr/share/licenses/\$pkgname/"
    grep -qF 'install -Dm644 "$srcdir/${_files[i]}"' "$pkgbuild" || echo "the model file is not installed with mode 644"
    grep -qE '^        return 1$' "$pkgbuild" || echo "_install_model does not fail (return 1) on an unknown model id"
    return 0
}

echo "== the repository's PKGBUILD"
pkgbuild=$top/packaging/arch/PKGBUILD
if [[ -f $pkgbuild ]]; then
    tagver=$(sed -n 's/^pkgver=//p' "$pkgbuild" | head -n1)
    if git -C "$top" rev-parse -q --verify "refs/tags/v$tagver" >/dev/null 2>&1; then
        echo "note: licence checksums compared against the tag v$tagver"
    else
        echo "note: tag v$tagver not present locally; licence checksums compared against the working tree"
    fi
fi
if [[ ! -f $pkgbuild ]]; then
    fail "packaging/arch/PKGBUILD is missing"
else
    out=$(check_pkgbuild "$pkgbuild")
    if [[ -z $out ]]; then
        ok "packaging/arch/PKGBUILD is in step with models.toml and licenses/"
    else
        fail "packaging/arch/PKGBUILD: $out"
    fi
fi

# mutate <description> <sed expression> <expected message>: a copy of the
# PKGBUILD, altered, must be refused with the message.
expect_bad() {
    local desc=$1 expr=$2 want=$3 copy=$tmp/PKGBUILD.$count out
    sed -E "$expr" "$pkgbuild" >"$copy"
    if cmp -s "$pkgbuild" "$copy"; then
        fail "$desc (fixture unchanged)"
        return
    fi
    out=$(check_pkgbuild "$copy")
    if grep -qF -- "$want" <<<"$out"; then ok "$desc"; else fail "$desc (no '$want'): $out"; fi
}

if [[ -f $pkgbuild ]]; then
    echo "== defects the check must catch"
    expect_bad "a model SHA-256 that differs from models.toml" \
        's/^    fa02222275c455638fa1190493b659d25ad31e86f1b6459f17bd501f02cbe43d$/    fa02222275c455638fa1190493b659d25ad31e86f1b6459f17bd501f02cbe43e/' \
        "sha256sums:"
    expect_bad "a licence SHA-256 that differs from licenses/" \
        's/^    5d8b13c7a4fbdaa33a29a853d174f2bdd4e7e9a393773c2885b61d31e97fe991$/    5d8b13c7a4fbdaa33a29a853d174f2bdd4e7e9a393773c2885b61d31e97fe992/' \
        "sha256sums:"
    expect_bad "two ids swapped" \
        '/^_ids=\(/,/^\)/{s/^    mediapipe-landscape$/    TMPID/;s/^    modnet$/    mediapipe-landscape/;s/^    TMPID$/    modnet/}' \
        "ids:"
    expect_bad "a release file renamed" \
        's/^    modnet_photographic\.onnx$/    modnet_photographic_v2.onnx/' \
        "files:"
    expect_bad "a package name that differs from its id" \
        '0,/^    omarchy-onnx-model-modnet$/s//    omarchy-onnx-model-modnet-x/' \
        "pkgname:"
    expect_bad "a package without its function" \
        's/^package_omarchy-onnx-model-modnet\(\)/package_omarchy-onnx-model-modnet2()/' \
        "no package_ function for: omarchy-onnx-model-modnet"
    expect_bad "a pkgver that is not x.y.z" 's/^pkgver=1\.0\.0$/pkgver=1.0/' "is not x.y.z"
    expect_bad "an architecture other than any" "s/^arch=\\('any'\\)$/arch=('x86_64')/" "arch is"
    expect_bad "source URLs of another release than pkgver" \
        's#^_release="\$url/releases/download/v\$pkgver"#_release="$url/releases/download/v0.9.0"#' \
        "source:"
    expect_bad "a licence declaration removed" \
        '0,/^    license=\(.Apache-2\.0.\)$/s///' \
        "license=('Apache-2.0') lines"
    expect_bad "a package description removed" \
        '0,/^    pkgdesc=.*$/s///' \
        "pkgdesc lines"
    expect_bad "a model file installed with another mode" \
        's/install -Dm644 "\$srcdir\/\$\{_files\[i\]\}"/install -Dm755 "$srcdir\/${_files[i]}"/' \
        "mode 644"
    expect_bad "_install_model that no longer fails on an unknown id" \
        '/^        return 1$/d' \
        "unknown model id"
    expect_bad "a licence installed elsewhere" \
        's#/usr/share/licenses/\$pkgname/LICENSE#/usr/share/doc/$pkgname/LICENSE#' \
        "the licence is not installed"

    # A PKGBUILD that fails to source.
    printf 'pkgbase=(\n' >"$tmp/broken"
    if grep -qF "cannot be sourced" <<<"$(check_pkgbuild "$tmp/broken" 2>/dev/null)"; then
        ok "a PKGBUILD that does not source"
    else
        fail "a PKGBUILD that does not source"
    fi
fi

if ((fails > 0)); then
    echo "$fails of $count check(s) failed"
    exit 1
fi
echo "all $count checks passed"
