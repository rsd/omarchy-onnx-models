# SPDX-License-Identifier: MIT OR Apache-2.0
"""The equivalence check of a model whose conversion is not byte-reproducible.

scripts/build-models.sh ships the supplied reference file of such a model
(models.toml: reproducible = false) only when a fresh conversion, made by the
same pinned recipe, is equivalent to it. This program decides that, from the
JSON summaries convert/verify_model.py --summary writes of the two files.
Standard library only (Python 3.11 or newer); run it with `python3 -I`.

The two files are equivalent when every one of these holds:

  ir_version      the same
  opset_imports   the same domains at the same versions
  inputs          the same graph inputs, in order: name, element type,
                  dimensions
  outputs         the same graph outputs, likewise
  initializers    the same tensors as a multiset, compared exactly: element
                  type, dimensions and the SHA-256 of the values (names are
                  not compared)
  nodes           the same multiset of (domain, op type, attributes) over
                  the nodes that are not no-ops (names and wiring are not
                  compared; the probes check the computation)
  probes          the same probe inputs (the smoke input among them), the
                  same output shapes, every output value finite, and the
                  largest absolute difference over every output value of
                  every probe at most the tolerance

A no-op, the only kind of node left out of the node comparison, is a Reshape
of the default ONNX domain whose data input and output have the same, fully
static shape and element type after ONNX shape inference: it returns its
input unchanged. Its shape operand is still an initializer and is still
compared. The summaries must name this rule (noop_rule) for the check to run.

Usage:
  equivalence.py REFERENCE.json FRESH.json --tolerance T [--facts FILE --id ID]

Prints the result. With --facts, appends the result to FILE as build facts
(ID.equivalence_*, one KEY<TAB>VALUE line each) for the manifest.
Exit status: 0 equivalent, 1 not equivalent, 2 usage or input error.
"""

import base64
import collections
import json
import math
import sys
from array import array

SUMMARY_SCHEMA = 1
NOOP_RULE = "reshape-same-static-shape"
NOOP_RULE_TEXT = (
    "a Reshape whose data input and output have the same fully static shape "
    "and element type after ONNX shape inference (an identity)"
)


class InputError(Exception):
    pass


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def multiset(items):
    return collections.Counter(canonical(i) for i in items)


def decode_floats(text):
    """float32 little-endian values from base64 text."""
    try:
        raw = base64.b64decode(text, validate=True)
    except (ValueError, TypeError) as e:
        raise InputError(f"a probe output is not base64: {e}")
    if len(raw) % 4:
        raise InputError("a probe output is not a whole number of float32 values")
    values = array("f")
    values.frombytes(raw)
    if sys.byteorder == "big":
        values.byteswap()
    return values


def max_abs_diff(a, b):
    """The largest |a - b|, or None when a value is not finite."""
    worst = 0.0
    for x, y in zip(a, b):
        if not (math.isfinite(x) and math.isfinite(y)):
            return None
        d = abs(x - y)
        if d > worst:
            worst = d
    return worst


def require(summary, key, kind):
    if not isinstance(summary, dict) or key not in summary or not isinstance(summary[key], kind):
        raise InputError(f"summary: missing or malformed {key}")
    return summary[key]


def compare(reference, fresh, tolerance):
    """Compares two summaries. Returns a dict: equivalent (bool), checks (a
    list of [name, ok, detail]) and the numbers the manifest records."""
    if isinstance(tolerance, bool) or not isinstance(tolerance, (int, float)) or not (
        math.isfinite(tolerance) and tolerance >= 0
    ):
        raise InputError(f"bad tolerance: {tolerance!r}")
    for s in (reference, fresh):
        if require(s, "summary_schema", int) != SUMMARY_SCHEMA:
            raise InputError(f"summary_schema {s['summary_schema']}, expected {SUMMARY_SCHEMA}")
        if require(s, "noop_rule", str) != NOOP_RULE:
            raise InputError(f"noop_rule {s['noop_rule']!r}, expected {NOOP_RULE!r}")
        for key in ("inputs", "outputs", "initializers", "nodes", "probes"):
            require(s, key, list)
        require(s, "opset_imports", dict)
        require(s, "ir_version", int)
        for n in s["nodes"]:
            if not (isinstance(n, dict) and isinstance(n.get("noop"), bool)):
                raise InputError("summary: a node without a boolean noop")
            if n["noop"] and not (n.get("op_type") == "Reshape" and n.get("domain") in ("", "ai.onnx")):
                raise InputError(f"summary: a {n.get('op_type')} node marked as a no-op; only Reshape can be")

    checks = []

    def check(name, ok, detail):
        checks.append([name, bool(ok), detail])

    check("ir_version", reference["ir_version"] == fresh["ir_version"],
          f"reference {reference['ir_version']}, fresh {fresh['ir_version']}")
    check("opset_imports", reference["opset_imports"] == fresh["opset_imports"],
          f"reference {canonical(reference['opset_imports'])}, fresh {canonical(fresh['opset_imports'])}")
    for side in ("inputs", "outputs"):
        check(side, canonical(reference[side]) == canonical(fresh[side]),
              f"reference {canonical(reference[side])}, fresh {canonical(fresh[side])}")

    ri, fi = multiset(reference["initializers"]), multiset(fresh["initializers"])
    check("initializers", ri == fi,
          f"{len(reference['initializers'])} and {len(fresh['initializers'])} tensors; "
          f"only in the reference {sum((ri - fi).values())}, only in the fresh file {sum((fi - ri).values())}")

    def ops(summary):
        return multiset(
            {"domain": n.get("domain"), "op_type": n.get("op_type"), "attributes": n.get("attributes")}
            for n in summary["nodes"] if not n["noop"]
        )

    ignored_ref = sum(n["noop"] for n in reference["nodes"])
    ignored_fresh = sum(n["noop"] for n in fresh["nodes"])
    ro, fo = ops(reference), ops(fresh)
    diff = sorted(json.loads(k)["op_type"] for k in ((ro - fo) + (fo - ro)).elements())
    check("nodes", ro == fo,
          f"{sum(ro.values())} and {sum(fo.values())} nodes compared; no-ops left out: "
          f"reference {ignored_ref}, fresh {ignored_fresh}"
          + (f"; differing: {', '.join(diff)}" if diff else ""))

    names = [p.get("name") if isinstance(p, dict) else None for p in reference["probes"]]
    worst = 0.0
    probes_ok = bool(names) and "smoke" in names and names == [
        p.get("name") if isinstance(p, dict) else None for p in fresh["probes"]]
    detail = f"probes {names}"
    if probes_ok:
        for rp, fp in zip(reference["probes"], fresh["probes"]):
            if rp.get("shape") != fp.get("shape") or not isinstance(rp.get("shape"), list):
                probes_ok, detail = False, f"probe {rp['name']}: output shapes {rp.get('shape')} and {fp.get('shape')}"
                break
            a = decode_floats(rp.get("float32_le_base64", ""))
            b = decode_floats(fp.get("float32_le_base64", ""))
            want = math.prod(rp["shape"])
            if len(a) != want or len(b) != want:
                probes_ok, detail = False, f"probe {rp['name']}: {len(a)} and {len(b)} values, expected {want}"
                break
            d = max_abs_diff(a, b)
            if d is None:
                probes_ok, detail = False, f"probe {rp['name']}: an output value is not finite"
                break
            worst = max(worst, d)
        else:
            probes_ok = worst <= tolerance
            detail = f"{len(names)} probes, max abs diff {worst!r}, tolerance {tolerance!r}"
    else:
        detail = (f"probe names differ or no smoke probe: reference {names}, fresh "
                  f"{[p.get('name') if isinstance(p, dict) else None for p in fresh['probes']]}")
    check("probes", probes_ok, detail)

    return {
        "equivalent": all(ok for _, ok, _ in checks),
        "checks": checks,
        "tolerance": float(tolerance),
        "max_abs_diff": worst,
        "probes": names,
        "initializers": len(reference["initializers"]),
        "nodes_compared": sum(ro.values()),
        "ignored_reference": ignored_ref,
        "ignored_fresh": ignored_fresh,
        "reference_sha256": reference.get("sha256"),
        "fresh_sha256": fresh.get("sha256"),
        "fresh_size": fresh.get("size"),
    }


def facts(result, model_id):
    """The build facts of an equivalent result, as (key, value) pairs."""
    p = f"{model_id}.equivalence"
    return [
        (f"{p}_tolerance", repr(result["tolerance"])),
        (f"{p}_max_abs_diff", repr(float(result["max_abs_diff"]))),
        (f"{p}_probes", " ".join(result["probes"])),
        (f"{p}_initializers", str(result["initializers"])),
        (f"{p}_nodes_compared", str(result["nodes_compared"])),
        (f"{p}_ignored_reference", str(result["ignored_reference"])),
        (f"{p}_ignored_fresh", str(result["ignored_fresh"])),
        (f"{p}_fresh_sha256", str(result["fresh_sha256"])),
        (f"{p}_fresh_size", str(result["fresh_size"])),
    ]


def load_summary(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError) as e:
        raise InputError(f"cannot read {path}: {e}")


def main(argv):
    args = list(argv)
    tolerance = facts_file = model_id = None
    paths = []
    while args:
        a = args.pop(0)
        if a in ("--tolerance", "--facts", "--id"):
            if not args:
                raise InputError(f"{a} needs a value")
            v = args.pop(0)
            if a == "--tolerance":
                try:
                    tolerance = float(v)
                except ValueError:
                    raise InputError(f"bad tolerance: {v!r}")
            elif a == "--facts":
                facts_file = v
            else:
                model_id = v
        elif a.startswith("-"):
            raise InputError(f"unknown option {a}")
        else:
            paths.append(a)
    if len(paths) != 2 or tolerance is None or (facts_file is None) != (model_id is None):
        raise InputError("usage: equivalence.py REFERENCE.json FRESH.json --tolerance T [--facts FILE --id ID]")
    result = compare(load_summary(paths[0]), load_summary(paths[1]), tolerance)
    for name, ok, detail in result["checks"]:
        print(f"{'ok  ' if ok else 'FAIL'} {name}: {detail}")
    print("equivalent" if result["equivalent"] else "NOT equivalent")
    if result["equivalent"] and facts_file is not None:
        with open(facts_file, "a", encoding="utf-8") as f:
            for key, value in facts(result, model_id):
                if "\t" in value or "\n" in value:
                    raise InputError(f"a fact value with a tab or newline: {key}")
                f.write(f"{key}\t{value}\n")
    return 0 if result["equivalent"] else 1


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except InputError as e:
        print(f"equivalence.py: {e}", file=sys.stderr)
        sys.exit(2)
