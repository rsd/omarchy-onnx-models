#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Runs every check of this repository that needs no network and no
# conversion environment: shellcheck and `bash -n` over every shell script
# (the hooks, scripts/, scripts/lib/, scripts/tests/), a syntax check of the
# Python programs with the system python3, every scripts/tests/*-test.sh,
# and the guard over the whole tree. Scratch files go to mktemp, never into
# the working tree.
#
#   scripts/test.sh                      # shellcheck from PATH, else uvx
#   SHELLCHECK=/path/to/shellcheck scripts/test.sh
#
# Without shellcheck on PATH and without SHELLCHECK, it runs
# `uvx --from shellcheck-py shellcheck` when uvx is installed (from uv's
# cache once it has been fetched).
# Exits non-zero when any check fails.
set -uo pipefail
shopt -s nullglob

top=$(cd "$(dirname "$0")/.." && pwd)
cd "$top" || exit 2

if [[ -n ${SHELLCHECK:-} ]]; then
    shellcheck=("$SHELLCHECK")
elif command -v shellcheck >/dev/null 2>&1; then
    shellcheck=(shellcheck)
elif command -v uvx >/dev/null 2>&1; then
    shellcheck=(uvx --from shellcheck-py shellcheck)
else
    echo "shellcheck not found: install it, install uv (for uvx), or set SHELLCHECK=/path/to/shellcheck" >&2
    exit 2
fi
if ! "${shellcheck[@]}" --version >/dev/null 2>&1; then
    echo "shellcheck does not run: ${shellcheck[*]}" >&2
    exit 2
fi

failed=()
run() { # run <name> <command...>
    local name=$1
    shift
    echo "== $name"
    if "$@"; then
        echo "-- ok: $name"
    else
        echo "-- FAIL: $name"
        failed+=("$name")
    fi
}

hooks=(.githooks/pre-commit .githooks/pre-merge-commit .githooks/pre-push)
bash_scripts=(scripts/*.sh scripts/lib/*.sh scripts/tests/*.sh)
run "shellcheck (hooks and scripts)" "${shellcheck[@]}" -x "${hooks[@]}" "${bash_scripts[@]}"
syntax() {
    local f status=0
    for f in "${bash_scripts[@]}"; do bash -n "$f" || status=1; done
    for f in "${hooks[@]}"; do sh -n "$f" || status=1; done
    return "$status"
}
run "bash -n / sh -n" syntax
# Every script but the sourced library is executable.
executable() {
    local f status=0
    for f in "${hooks[@]}" scripts/*.sh scripts/tests/*.sh; do
        [[ -x $f ]] || { echo "not executable: $f"; status=1; }
    done
    return "$status"
}
run "executable bits" executable
# The Python programs compile (no third-party import is executed); the
# bytecode goes to a temporary directory, never next to the sources.
pycompile() {
    local cache
    cache=$(mktemp -d)
    python3 -I -c 'import sys, py_compile
for f in sys.argv[2:]:
    py_compile.compile(f, cfile=sys.argv[1] + "/x.pyc", doraise=True)' "$cache" convert/*.py scripts/lib/*.py
    local status=$?
    rm -rf -- "$cache"
    return "$status"
}
run "python3 -I py_compile (convert/, scripts/lib/)" pycompile

for t in scripts/tests/*-test.sh; do
    run "${t#scripts/tests/}" "$t"
done
run "guard (--all)" scripts/check-no-models.sh --all

if ((${#failed[@]} > 0)); then
    printf 'FAILED: %s\n' "${failed[@]}"
    exit 1
fi
echo "all checks passed"
