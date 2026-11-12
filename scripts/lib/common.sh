# shellcheck shell=bash
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Functions shared by scripts/build-models.sh and its tests: checksums, the
# SHA256SUMS file, verified downloads, safe archive extraction and the build
# facts the manifest is written from. Sourced, never run. Nothing here
# touches the network except download_one, which the tests replace.

# The results of fetch_verified and reuse_verified, read by their callers.
# shellcheck disable=SC2034
FETCHED_PATH='' FETCHED_URL=''

# The only package index, and the interpreter of each environment (exact
# python-build-standalone releases, as uv names them); read by
# scripts/build-models.sh and scripts/lock-requirements.sh.
# shellcheck disable=SC2034
pypi_index=https://pypi.org/simple
# shellcheck disable=SC2034
declare -A env_python=([tflite]=3.12.16 [paddle]=3.10.22 [verify]=3.12.16)

# uv_clean <uv arguments>: uv without any configuration file (--no-config:
# no uv.toml, no pyproject.toml [tool.uv]) and without the variables of the
# environment that would bring in another package index or Python download
# location. The callers name the index themselves (--default-index).
uv_clean() {
    env -u UV_INDEX_URL -u UV_EXTRA_INDEX_URL -u UV_INDEX -u UV_DEFAULT_INDEX \
        -u UV_FIND_LINKS -u UV_CONFIG_FILE -u UV_INSECURE_HOST \
        -u UV_PYTHON_INSTALL_MIRROR -u UV_PYPY_INSTALL_MIRROR -u UV_PYTHON_DOWNLOADS_JSON_URL \
        -u PIP_INDEX_URL -u PIP_EXTRA_INDEX_URL -u PIP_FIND_LINKS \
        uv --no-config "$@"
}

# sha256_of <file>: prints the file's SHA-256 (64 lowercase hex digits).
sha256_of() {
    local out
    out=$(sha256sum -- "$1") || return 1
    printf '%s\n' "${out%% *}"
}

# is_sha256 <string>: true for 64 lowercase hex digits.
is_sha256() {
    [[ $1 =~ ^[0-9a-f]{64}$ ]]
}

# verify_sha256 <file> <expected>: 0 when the file's SHA-256 is <expected>,
# 1 (with a message on stderr) otherwise.
verify_sha256() {
    local file=$1 want=$2 got
    if ! is_sha256 "$want"; then
        echo "verify_sha256: not a SHA-256: $want" >&2
        return 1
    fi
    if [[ ! -f $file ]]; then
        echo "verify_sha256: no such file: $file" >&2
        return 1
    fi
    got=$(sha256_of "$file") || return 1
    if [[ $got != "$want" ]]; then
        printf 'checksum mismatch: %s\n  expected %s\n  got      %s\n' "$file" "$want" "$got" >&2
        return 1
    fi
}

# write_sha256sums <dir>: writes <dir>/SHA256SUMS, in the format of
# `sha256sum` (`sha256sum -c SHA256SUMS` in <dir> checks it), for every
# regular file of <dir> but SHA256SUMS itself, sorted by name. File names
# must be plain (letters, digits, dot, dash, underscore, plus).
write_sha256sums() {
    local dir=$1 path name sum lines=()
    [[ -d $dir ]] || { echo "write_sha256sums: not a directory: $dir" >&2; return 1; }
    for path in "$dir"/*; do
        name=${path##*/}
        [[ -f $path && $name != SHA256SUMS ]] || continue
        if [[ ! $name =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; then
            echo "write_sha256sums: refusing the file name: $name" >&2
            return 1
        fi
        sum=$(sha256_of "$path") || return 1
        lines+=("$sum  $name")
    done
    if ((${#lines[@]} == 0)); then
        echo "write_sha256sums: no file in $dir" >&2
        return 1
    fi
    printf '%s\n' "${lines[@]}" | LC_ALL=C sort -k2 >"$dir/SHA256SUMS"
}

# check_sha256sums <dir>: `sha256sum -c` of <dir>/SHA256SUMS, run in <dir>;
# also fails when a regular file of <dir> is not listed (its name compared
# literally with the name field of each line, never as a pattern).
check_sha256sums() {
    local dir=$1 path name status=0
    [[ -f $dir/SHA256SUMS ]] || { echo "check_sha256sums: no $dir/SHA256SUMS" >&2; return 1; }
    (cd "$dir" && sha256sum --check --strict --quiet SHA256SUMS) || return 1
    for path in "$dir"/*; do
        name=${path##*/}
        [[ -f $path && $name != SHA256SUMS ]] || continue
        # The name through the environment: awk -v would expand backslashes.
        if ! SUMS_NAME=$name awk '
            length($0) > 66 && substr($0, 1, 64) ~ /^[0-9a-f]+$/ && substr($0, 65, 2) == "  " &&
                substr($0, 67) == ENVIRON["SUMS_NAME"] { found = 1 }
            END { exit !found }' "$dir/SHA256SUMS"; then
            echo "check_sha256sums: $name is not listed in SHA256SUMS" >&2
            status=1
        fi
    done
    return "$status"
}

# download_one <url> <output file>: one HTTPS download, no credentials, no
# cookies. Replaced by the tests.
download_one() {
    curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' \
        --tlsv1.2 --retry 3 --retry-delay 2 --connect-timeout 30 \
        --output "$2" -- "$1"
}

# fetch_verified <parent dir> <file name> <sha256> <url>...: downloads the
# file from the URLs in order, each attempt into a new, empty directory under
# <parent dir>, and checks its SHA-256 before anything else reads it; the
# first download with the pinned SHA-256 wins. Sets FETCHED_PATH and
# FETCHED_URL. A failed download, or one with another SHA-256 (a host may
# answer HTTP 200 with an error or quota page), is removed and the next URL
# tried, every one checked against the same SHA-256. Status 0 on success;
# 3 when no URL gave the pinned file and at least one gave another file; 1
# when no URL answered at all.
fetch_verified() {
    local parent=$1 name=$2 sum=$3 url dir mismatch=0
    shift 3
    FETCHED_PATH='' FETCHED_URL=''
    [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] ||
        { echo "fetch_verified: refusing the file name: $name" >&2; return 2; }
    mkdir -p -- "$parent"
    for url in "$@"; do
        dir=$(mktemp -d "$parent/download.XXXXXX") || return 2
        echo "fetching $url" >&2
        if ! download_one "$url" "$dir/$name"; then
            echo "download failed: $url" >&2
            rm -rf -- "$dir"
            continue
        fi
        if ! verify_sha256 "$dir/$name" "$sum"; then
            echo "refusing $name from $url: wrong checksum; trying the next source" >&2
            rm -rf -- "$dir"
            mismatch=1
            continue
        fi
        FETCHED_PATH=$dir/$name FETCHED_URL=$url
        return 0
    done
    if ((mismatch)); then
        echo "no source gave $name with SHA-256 $sum" >&2
        return 3
    fi
    echo "no source answered for $name" >&2
    return 1
}

# reuse_verified <input dir> <parent dir> <file name> <sha256>: copies
# <input dir>/<file name> into a new directory under <parent dir> and checks
# its SHA-256 (a mismatch is a hard failure, status 3). Sets FETCHED_PATH and
# FETCHED_URL (to the local path). Status 1 when the file is not there, 2
# when it cannot be copied (unreadable, the disk full).
reuse_verified() {
    local src=$1/$3 parent=$2 name=$3 sum=$4 dir
    FETCHED_PATH='' FETCHED_URL=''
    [[ -f $src ]] || return 1
    mkdir -p -- "$parent"
    dir=$(mktemp -d "$parent/reuse.XXXXXX") || return 2
    if ! cp -- "$src" "$dir/$name"; then
        echo "could not copy $src" >&2
        rm -rf -- "$dir"
        return 2
    fi
    if ! verify_sha256 "$dir/$name" "$sum"; then
        echo "refusing $src: wrong checksum" >&2
        rm -rf -- "$dir"
        return 3
    fi
    FETCHED_PATH=$dir/$name FETCHED_URL=file://$(cd "$1" && pwd)/$name
}

# safe_unzip <zip> <dest dir>: extracts into <dest dir> (which must not
# exist yet) after refusing absolute paths, `..` components and symbolic
# links in the archive. unzip never overwrites (-n: of two entries with one
# name, the first is kept) and never asks (no terminal input).
safe_unzip() {
    local zip=$1 dest=$2 entry
    [[ ! -e $dest ]] || { echo "safe_unzip: $dest exists" >&2; return 1; }
    while IFS= read -r entry; do
        case /$entry/ in
            //* | */../*) echo "safe_unzip: refusing the entry: $entry" >&2; return 1 ;;
        esac
    done < <(unzip -Z1 "$zip")
    # Symbolic links: unzip -Z shows them as l in the first column.
    if unzip -Z "$zip" | grep -q '^l'; then
        echo "safe_unzip: refusing an archive with symbolic links: $zip" >&2
        return 1
    fi
    mkdir -p -- "$dest"
    unzip -q -n "$zip" -d "$dest" </dev/null
}

# fact <facts file> <key> <value>: records a build fact for the manifest. The
# value is one line.
fact() {
    local file=$1 key=$2 value=$3
    [[ $key != *$'\t'* && $key != *$'\n'* && $value != *$'\n'* ]] ||
        { echo "fact: a key or value with a tab or newline: $key" >&2; return 1; }
    printf '%s\t%s\n' "$key" "$value" >>"$file"
}
