#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Regenerates the hashed lock files requirements/<name>.lock from the exact
# pins of requirements/<name>.txt, for the Python version of each
# environment, against PyPI only:
#
#   scripts/lock-requirements.sh
#
# scripts/build-models.sh installs each environment from its lock file with
# hashes required (uv pip sync --require-hashes), so every wheel it installs
# is one whose SHA-256 the lock lists. Run this after changing a pin in
# requirements/*.txt, and commit both files together; the lock must name
# exactly the packages and versions of the .txt (scripts/tests/build-lib-test.sh
# checks it). uv runs with --no-config, an explicit --default-index and
# without the index variables of the environment, so that neither a uv.toml
# nor UV_INDEX_URL (or the like) can bring another index in.
set -euo pipefail

top=$(cd "$(dirname "$0")/.." && pwd)
cd "$top"
# shellcheck source=scripts/lib/common.sh
. "$top/scripts/lib/common.sh"

for name in tflite paddle verify; do
    echo "requirements/$name.lock (Python ${env_python[$name]})"
    uv_clean pip compile --quiet --generate-hashes \
        --python-version "${env_python[$name]}" --python-platform x86_64-unknown-linux-gnu \
        --default-index "$pypi_index" \
        --custom-compile-command "scripts/lock-requirements.sh" \
        --output-file "requirements/$name.lock" "requirements/$name.txt"
done
