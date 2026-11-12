#!/usr/bin/env bash
# shellcheck disable=SC2016 # Python programs in single quotes, on purpose
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Tests of the equivalence check of a model that is not byte-reproducible
# (scripts/lib/equivalence.py), on small fake summaries in the format of
# convert/verify_model.py --summary, written here under mktemp: no model, no
# onnx, no onnxruntime, no network. System python3 (3.11 or newer).
# Usage: scripts/tests/equivalence-test.sh. Exits non-zero on any failure.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
top=$(cd "$here/../.." && pwd)
eq=$top/scripts/lib/equivalence.py

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fails=0 count=0
ok() { count=$((count + 1)); echo "ok   $1"; }
fail() { count=$((count + 1)); echo "FAIL $1"; fails=$((fails + 1)); }
# reported <description> <fixed string>: the last report must hold it.
reported() {
    if grep -qF -- "$2" "$tmp/out"; then ok "$1"; else fail "$1: $(cat "$tmp/out")"; fi
}
# status_is <description> <want> <got>
status_is() {
    if (($3 == $2)); then ok "$1"; else fail "$1 (exit $3, want $2)"; fi
}

# mk <file> <python statements on s, the summary>: writes a fake summary. The
# base has two initializers, four nodes (one of them a no-op
# Reshape) and three probes of four float32 values each.
mk() {
    python3 -I -c '
import base64, json, struct, sys
def f32(*v):
    return base64.b64encode(struct.pack("<%df" % len(v), *v)).decode()
def probe(name, *v):
    return {"name": name, "shape": [1, len(v)], "float32_le_base64": f32(*v)}
def node(op, attrs=(), noop=False):
    return {"domain": "ai.onnx", "op_type": op, "attributes": [list(a) for a in attrs], "noop": noop}
s = {
    "summary_schema": 1,
    "noop_rule": "reshape-same-static-shape",
    "file": "m.onnx", "sha256": "0" * 64, "size": 100,
    "ir_version": 8,
    "opset_imports": {"ai.onnx": 17, "ai.onnx.ml": 2},
    "inputs": [{"name": "x", "type": "FLOAT", "dims": [1, 4]}],
    "outputs": [{"name": "y", "type": "FLOAT", "dims": [1, 4]}],
    "initializers": [
        {"type": "FLOAT", "dims": [4], "sha256": "a" * 64},
        {"type": "INT64", "dims": [2], "sha256": "b" * 64},
    ],
    "nodes": [
        node("Conv", [("strides", "INTS", [1, 1])]),
        node("Reshape", noop=True),
        node("Relu"),
        node("Sigmoid"),
    ],
    "probes": [probe("smoke", 0.0, 0.25, 0.5, 1.0), probe("low", 0.0, 0.0, 0.0, 0.0),
               probe("high", 1.0, 1.0, 1.0, 1.0)],
}
exec(sys.argv[2])
json.dump(s, open(sys.argv[1], "w"))' "$1" "${2:-pass}"
}

mk "$tmp/ref.json"

# expect <description> <exit status> <python on s, the fresh summary> [tolerance]
expect() {
    local desc=$1 want=$2 mutation=$3 tol=${4:-1e-6} status=0
    mk "$tmp/fresh.json" "$mutation"
    python3 -I "$eq" "$tmp/ref.json" "$tmp/fresh.json" --tolerance "$tol" >"$tmp/out" 2>&1 || status=$?
    if ((status == want)); then ok "$desc"; else fail "$desc (exit $status, want $want): $(cat "$tmp/out")"; fi
}

echo "== equivalent"
expect "the same summary" 0 'pass'
expect "another file (sha256, size) with the same content" 0 's["sha256"] = "1" * 64; s["size"] = 101'
expect "initializers in another order" 0 's["initializers"].reverse()'
expect "nodes in another order" 0 's["nodes"].reverse()'
expect "one more no-op Reshape" 0 's["nodes"].append(node("Reshape", noop=True))'
reported "the ignored no-ops are counted on each side" 'no-ops left out: reference 1, fresh 2'
expect "a no-op Reshape fewer" 0 'del s["nodes"][1]'
expect "an output difference below the tolerance" 0 's["probes"][0] = probe("smoke", 0.0, 0.25, 0.5000004, 1.0)'
expect "an output difference of exactly the tolerance" 0 \
    's["probes"][2] = probe("high", 1.0, 1.0, 1.0, 0.9990234375)' 0.0009765625
expect "a zero tolerance with identical outputs" 0 'pass' 0

echo "== not equivalent"
expect "an output difference above the tolerance" 1 's["probes"][0] = probe("smoke", 0.0, 0.25, 0.500003, 1.0)'
reported "the report names the probes and the difference" 'FAIL probes: 3 probes, max abs diff'
expect "any difference with a zero tolerance" 1 's["probes"][1] = probe("low", 0.0, 0.0, 0.0, 1e-30)' 0
expect "a NaN output" 1 's["probes"][1] = probe("low", 0.0, float("nan"), 0.0, 0.0)'
expect "an infinite output" 1 's["probes"][2] = probe("high", 1.0, float("inf"), 1.0, 1.0)'
expect "a probe output of another shape" 1 's["probes"][1] = probe("low", 0.0, 0.0, 0.0)'
expect "a probe fewer" 1 'del s["probes"][2]'
expect "probes in another order" 1 's["probes"].reverse()'
expect "no smoke probe on either side" 1 's["probes"][0]["name"] = "other"'
mk "$tmp/ref-nosmoke.json" 's["probes"][0]["name"] = "other"'
status=0
python3 -I "$eq" "$tmp/ref-nosmoke.json" "$tmp/ref-nosmoke.json" --tolerance 1e-6 >"$tmp/out" 2>&1 || status=$?
status_is "two summaries without a smoke probe are refused" 1 "$status"
expect "a changed initializer" 1 's["initializers"][0]["sha256"] = "c" * 64'
reported "the report counts the differing tensors" 'only in the reference 1, only in the fresh file 1'
expect "an initializer of another shape" 1 's["initializers"][0]["dims"] = [2, 2]'
expect "an initializer more" 1 's["initializers"].append({"type": "FLOAT", "dims": [4], "sha256": "a" * 64})'
expect "an initializer fewer" 1 'del s["initializers"][1]'
expect "an extra operator" 1 's["nodes"].append(node("Relu"))'
reported "the report names the differing operator" 'differing: Relu'
expect "an operator replaced" 1 's["nodes"][2] = node("HardSwish")'
expect "a Reshape that is not a no-op, more" 1 's["nodes"].append(node("Reshape"))'
expect "another attribute value" 1 's["nodes"][0] = node("Conv", [("strides", "INTS", [2, 2])])'
expect "another domain" 1 's["nodes"][2]["domain"] = "com.microsoft"'
expect "another opset" 1 's["opset_imports"]["ai.onnx"] = 13'
expect "an opset import fewer" 1 'del s["opset_imports"]["ai.onnx.ml"]'
expect "another IR version" 1 's["ir_version"] = 9'
expect "another input name" 1 's["inputs"][0]["name"] = "input"'
expect "another input shape" 1 's["inputs"][0]["dims"] = [1, "n"]'
expect "another output type" 1 's["outputs"][0]["type"] = "FLOAT16"'

echo "== refused input (status 2)"
expect "a node other than Reshape marked as a no-op" 2 's["nodes"].append(node("Identity", noop=True))'
expect "a node without a noop field" 2 'del s["nodes"][0]["noop"]'
expect "another no-op rule" 2 's["noop_rule"] = "anything-goes"'
expect "another summary schema" 2 's["summary_schema"] = 2'
expect "a summary without probes" 2 'del s["probes"]'
expect "a probe that is not base64" 2 's["probes"][0]["float32_le_base64"] = "not base64!"'
expect "a negative tolerance" 2 'pass' -1e-6
expect "a NaN tolerance" 2 'pass' nan
status=0
python3 -I "$eq" "$tmp/ref.json" --tolerance 1e-6 >/dev/null 2>&1 || status=$?
status_is "one summary only is a usage error" 2 "$status"
status=0
python3 -I "$eq" "$tmp/ref.json" "$tmp/ref.json" >/dev/null 2>&1 || status=$?
status_is "no tolerance is a usage error" 2 "$status"
status=0
python3 -I "$eq" "$tmp/ref.json" "$tmp/nope.json" --tolerance 1e-6 >/dev/null 2>&1 || status=$?
status_is "a missing summary is an input error" 2 "$status"
status=0
python3 -I "$eq" "$tmp/ref.json" "$tmp/ref.json" --tolerance 1e-6 --facts "$tmp/f.tsv" >/dev/null 2>&1 || status=$?
status_is "--facts without --id is a usage error" 2 "$status"

echo "== build facts"
mk "$tmp/fresh.json" 's["sha256"] = "1" * 64; s["size"] = 101; s["nodes"].append(node("Reshape", noop=True)); s["probes"][0] = probe("smoke", 0.0, 0.25, 0.5000004, 1.0)'
: >"$tmp/facts.tsv"
if python3 -I "$eq" "$tmp/ref.json" "$tmp/fresh.json" --tolerance 1e-6 --facts "$tmp/facts.tsv" --id mp >/dev/null 2>&1 &&
    python3 -I -c '
import sys
facts = dict(line.rstrip("\n").split("\t", 1) for line in open(sys.argv[1]))
want = {
    "mp.equivalence_tolerance": "1e-06",
    "mp.equivalence_probes": "smoke low high",
    "mp.equivalence_initializers": "2",
    "mp.equivalence_nodes_compared": "3",
    "mp.equivalence_ignored_reference": "1",
    "mp.equivalence_ignored_fresh": "2",
    "mp.equivalence_fresh_sha256": "1" * 64,
    "mp.equivalence_fresh_size": "101",
}
for k, v in want.items():
    assert facts.get(k) == v, (k, facts.get(k))
d = float(facts["mp.equivalence_max_abs_diff"])
assert 3e-7 < d < 5e-7, d
assert len(facts) == 9, sorted(facts)' "$tmp/facts.tsv"; then
    ok "an equivalent result appends its facts"
else
    fail "facts: $(cat "$tmp/facts.tsv")"
fi
mk "$tmp/fresh.json" 's["ir_version"] = 9'
: >"$tmp/facts.tsv"
status=0
python3 -I "$eq" "$tmp/ref.json" "$tmp/fresh.json" --tolerance 1e-6 --facts "$tmp/facts.tsv" --id mp >/dev/null 2>&1 || status=$?
if ((status == 1)) && [[ ! -s $tmp/facts.tsv ]]; then
    ok "a result that is not equivalent writes no facts"
else
    fail "not equivalent: exit $status, facts: $(cat "$tmp/facts.tsv")"
fi

if ((fails > 0)); then
    echo "$fails of $count check(s) failed"
    exit 1
fi
echo "all $count checks passed"
