# SPDX-License-Identifier: MIT OR Apache-2.0
"""Reads the model table (models.toml) for scripts/build-models.sh and the tests.

Standard library only (Python 3.11 or newer, for tomllib); run it with
`python3 -I`. Subcommands:

  models.py [--models FILE] ids [--kind KIND]
      the model ids, one per line, in table order
  models.py [--models FILE] get ID KEY
      one field; a list prints one item per line; KEY may be dotted
      (input.name, output.shape)
  models.py [--models FILE] reproducible ID
      "yes" when the model's conversion is byte-reproducible (the default),
      "no" when models.toml sets reproducible = false
  models.py [--models FILE] check [--repo DIR]
      the table's consistency: every field present and well formed, unique
      ids and file names, a licences/<id>/LICENSE and NOTICE per model, the
      NOTICE at the top holding each model's notice, the conversion field
      and the model's NOTICE naming the model's opset when they name one,
      docs/models.md listing each model's file name and checksums, and no
      checksum in README.md, docs/models.md or docs/release.md that the
      table does not hold
  models.py [--models FILE] manifest DIST FACTS
      writes DIST/MANIFEST.toml for the model files present in DIST, from
      the table and the build facts in FACTS (lines of KEY<TAB>VALUE)

Exit status: 0 success, 1 a failed check, 2 usage or input error.
"""

import hashlib
import json
import math
import os
import re
import sys
import tomllib

HEX64 = re.compile(r"^[0-9a-f]{64}$")
ID = re.compile(r"^[a-z0-9][a-z0-9-]*$")
FILE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*\.onnx$")
DIM = re.compile(r"^[A-Za-z_][A-Za-z0-9_.]*$")
KINDS = ("tflite", "paddle", "copy")
STRING_FIELDS = (
    "id", "file", "sha256", "kind", "input_file", "input_sha256", "licence",
    "licence_url", "project_url", "model_card_url", "training_data",
    "conversion", "preprocessing",
)
URL_FIELDS = ("licence_url", "project_url", "model_card_url")


class UsageError(Exception):
    pass


def load(path):
    try:
        with open(path, "rb") as f:
            table = tomllib.load(f)
    except (OSError, tomllib.TOMLDecodeError) as e:
        raise UsageError(f"cannot read {path}: {e}")
    models = table.get("models")
    if not isinstance(models, list):
        raise UsageError(f"{path}: no [[models]] table")
    return table, models


def find(models, model_id):
    for m in models:
        if m.get("id") == model_id:
            return m
    raise UsageError(f"unknown model id: {model_id}")


def lookup(model, key):
    value = model
    for part in key.split("."):
        if not isinstance(value, dict) or part not in value:
            raise UsageError(f"model {model.get('id')}: no field {key}")
        value = value[part]
    return value


def shape_ok(shape):
    return (
        isinstance(shape, list)
        and len(shape) > 0
        and all(
            (isinstance(d, int) and not isinstance(d, bool) and d > 0)
            or (isinstance(d, str) and DIM.match(d))
            for d in shape
        )
    )


def check_model(m, errors):
    mid = m.get("id", "?")

    def err(msg):
        errors.append(f"{mid}: {msg}")

    for key in STRING_FIELDS:
        if not isinstance(m.get(key), str) or not m[key].strip():
            err(f"missing or empty field {key}")
    if errors and any(e.startswith(f"{mid}: missing") for e in errors):
        return
    if not ID.match(m["id"]):
        err(f"bad id {m['id']!r}")
    if not FILE.match(m["file"]):
        err(f"bad file name {m['file']!r}")
    for key in ("sha256", "input_sha256"):
        if not HEX64.match(m[key]):
            err(f"{key} is not 64 lowercase hex digits")
    size = m.get("size")
    if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
        err("size is not a positive integer")
    if m["kind"] not in KINDS:
        err(f"unknown kind {m['kind']!r}")
    if m["kind"] == "copy" and m["sha256"] != m["input_sha256"]:
        err("kind copy: sha256 and input_sha256 differ")
    rep = m.get("reproducible", True)
    tol = m.get("equivalence_tolerance")
    if not isinstance(rep, bool):
        err("reproducible must be true or false")
    elif rep:
        if "equivalence_tolerance" in m:
            err("equivalence_tolerance is only for a model with reproducible = false")
    else:
        if m["kind"] == "copy":
            err("kind copy: a copied file is always reproducible")
        if not (
            isinstance(tol, float) and math.isfinite(tol) and 0 <= tol <= 1e-3
        ):
            err("reproducible = false needs equivalence_tolerance, a float in [0, 1e-3]")
    if m["kind"] == "paddle" and not (
        isinstance(m.get("paddle_model_dir"), str)
        and re.match(r"^[A-Za-z0-9][A-Za-z0-9._-]*$", m["paddle_model_dir"])
    ):
        err("kind paddle: missing or bad paddle_model_dir")
    if m["kind"] == "tflite" and not (
        isinstance(m.get("tf2onnx_opset"), int) and not isinstance(m["tf2onnx_opset"], bool)
        and m["tf2onnx_opset"] >= 14
    ):
        err("kind tflite: tf2onnx_opset must be an integer >= 14")
    opset = m.get("opset")
    if not (isinstance(opset, int) and not isinstance(opset, bool) and opset >= 1):
        err("opset must be a positive integer (the ai.onnx opset of the release file)")
    else:
        if m["kind"] == "tflite" and m.get("tf2onnx_opset") != opset:
            err(f"kind tflite: opset {opset} differs from tf2onnx_opset {m.get('tf2onnx_opset')}")
        if not mentions_opset(m["conversion"], opset):
            err(f"conversion mentions an opset but not opset {opset}")
    if "/" in m["input_file"] or m["input_file"].startswith("."):
        err("input_file must be a plain file name")
    urls = m.get("input_urls")
    if not isinstance(urls, list) or not urls:
        err("input_urls is missing or empty")
    elif not all(isinstance(u, str) and u.startswith("https://") for u in urls):
        err("every input_urls entry must be an https:// URL")
    for key in URL_FIELDS:
        if not m[key].startswith("https://"):
            err(f"{key} is not an https:// URL")
    for side in ("input", "output"):
        io = m.get(side)
        if not isinstance(io, dict):
            err(f"missing [models.{side}]")
            continue
        if not isinstance(io.get("name"), str) or not io["name"]:
            err(f"{side}.name missing")
        if not shape_ok(io.get("shape")):
            err(f"{side}.shape missing or malformed")
    inp = m.get("input")
    if isinstance(inp, dict):
        vr = inp.get("value_range")
        if not (
            isinstance(vr, list) and len(vr) == 2
            and all(isinstance(v, (int, float)) for v in vr) and vr[0] < vr[1]
        ):
            err("input.value_range must be [low, high]")
    for side in ("input", "output"):
        io = m.get(side)
        if not (isinstance(io, dict) and shape_ok(io.get("shape"))):
            continue
        if any(isinstance(d, str) for d in io["shape"]):
            smoke = io.get("smoke_shape")
            if not (
                isinstance(smoke, list) and len(smoke) == len(io["shape"])
                and all(isinstance(d, int) and not isinstance(d, bool) and d > 0 for d in smoke)
                and all(isinstance(s, str) or s == d for s, d in zip(io["shape"], smoke))
            ):
                err(f"a dynamic {side} shape needs {side}.smoke_shape matching its static dimensions")


def mentions_opset(text, opset):
    """True when the text names no opset, or names this one ("opset N")."""
    return not re.search(r"\bopset\b", text) or re.search(rf"\bopset {opset}\b", text) is not None


def read_text(path, errors):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError as e:
        errors.append(f"cannot read {path}: {e}")
        return None


def cmd_check(models, repo):
    errors = []
    for m in models:
        if not isinstance(m, dict):
            errors.append("a [[models]] entry is not a table")
            continue
        check_model(m, errors)
    if errors:
        return errors
    for key in ("id", "file"):
        seen = set()
        for m in models:
            if m[key] in seen:
                errors.append(f"duplicate {key} {m[key]!r}")
            seen.add(m[key])
    if repo is None:
        return errors

    notice_all = read_text(os.path.join(repo, "NOTICE"), errors)
    readme = read_text(os.path.join(repo, "README.md"), errors)  # only scanned for stray checksums
    doc = read_text(os.path.join(repo, "docs", "models.md"), errors)
    release = read_text(os.path.join(repo, "docs", "release.md"), errors) if os.path.exists(
        os.path.join(repo, "docs", "release.md")) else None
    licence_texts = {}
    for m in models:
        mid = m["id"]
        ldir = os.path.join(repo, "licenses", mid)
        lic = read_text(os.path.join(ldir, "LICENSE"), errors)
        notice = read_text(os.path.join(ldir, "NOTICE"), errors)
        if lic is not None:
            first = licence_texts.setdefault(m["licence"], lic)
            if first != lic:
                errors.append(f"{mid}: licenses/{mid}/LICENSE differs from another {m['licence']} licence file")
        if notice is not None:
            if not notice.strip():
                errors.append(f"{mid}: licenses/{mid}/NOTICE is empty")
            elif notice_all is not None and notice.strip() not in notice_all:
                errors.append(f"{mid}: NOTICE does not hold licenses/{mid}/NOTICE")
            if not mentions_opset(" ".join(notice.split()), m["opset"]):
                errors.append(f"{mid}: licenses/{mid}/NOTICE mentions an opset but not opset {m['opset']}")
        if doc is not None:
            for value in (m["file"], m["sha256"], m["input_sha256"]):
                if value not in doc:
                    errors.append(f"{mid}: docs/models.md does not list {value}")
    # No stray checksum: every 64-hex string in README.md, docs/models.md or docs/release.md is one of the table's.
    known = {m["sha256"] for m in models} | {m["input_sha256"] for m in models}
    for name, text in (("README.md", readme), ("docs/models.md", doc), ("docs/release.md", release)):
        if text is None:
            continue
        for h in sorted(set(re.findall(r"(?<![0-9a-f])[0-9a-f]{64}(?![0-9a-f])", text)) - known):
            errors.append(f"{name}: checksum {h} is not in the model table")
    return errors


def read_facts(path):
    facts = {}
    try:
        with open(path, encoding="utf-8") as f:
            for n, line in enumerate(f, 1):
                line = line.rstrip("\n")
                if not line:
                    continue
                if "\t" not in line:
                    raise UsageError(f"{path}:{n}: not KEY<TAB>VALUE")
                key, value = line.split("\t", 1)
                facts[key] = value
    except OSError as e:
        raise UsageError(f"cannot read {path}: {e}")
    return facts


def toml_value(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        # A JSON string is a valid TOML basic string for these contents.
        return json.dumps(v, ensure_ascii=False)
    if isinstance(v, list):
        return "[" + ", ".join(toml_value(x) for x in v) + "]"
    raise TypeError(type(v))


def file_digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


VENV_OF_KIND = {"tflite": "tflite", "paddle": "paddle", "copy": None}


def cmd_manifest(table, models, dist, facts_path):
    facts = read_facts(facts_path)

    def fact(key, default=None):
        if key in facts:
            return facts[key]
        if default is not None:
            return default
        raise UsageError(f"{facts_path}: no fact {key}")

    lines = [
        "# The release manifest, written by scripts/build-models.sh from models.toml.",
        "# Every file of the release but this one and SHA256SUMS is listed with its",
        "# size and SHA-256; SHA256SUMS covers this file too.",
        "",
        f"schema = {toml_value(table.get('schema', 1))}",
        f"project = {toml_value(fact('project', 'omarchy-onnx-models'))}",
        f"source_revision = {toml_value(fact('source_revision', 'unknown'))}",
        "",
    ]
    present = [m for m in models if os.path.isfile(os.path.join(dist, m["file"]))]
    if not present:
        raise UsageError(f"{dist}: no model file of the table")
    for m in present:
        path = os.path.join(dist, m["file"])
        venv = VENV_OF_KIND[m["kind"]]
        tools = []
        if venv:
            tools.append(f"python=={fact(f'python.{venv}')}")
            tools += fact(f"freeze.{venv}").split()
        verify = [f"python=={fact('python.verify')}"] + fact("freeze.verify").split()
        steps = fact(f"{m['id']}.steps", m["conversion"])
        provenance = fact(f"{m['id']}.provenance")
        lines += [
            "[[file]]",
            f"name = {toml_value(m['file'])}",
            f"id = {toml_value(m['id'])}",
            f"size = {os.path.getsize(path)}",
            f"sha256 = {toml_value(file_digest(path))}",
            f"licence = {toml_value(m['licence'])}",
            f"licence_file = {toml_value(licence_file_name(m['licence']))}",
            'notice_file = "NOTICE"',
            f"licence_url = {toml_value(m['licence_url'])}",
            f"project_url = {toml_value(m['project_url'])}",
            f"model_card_url = {toml_value(m['model_card_url'])}",
            f"training_data = {toml_value(m['training_data'])}",
            f"source_file = {toml_value(m['input_file'])}",
            f"source_urls = {toml_value(m['input_urls'])}",
            f"source_fetched_from = {toml_value(fact(m['id'] + '.fetched_url'))}",
            f"source_sha256 = {toml_value(m['input_sha256'])}",
            f"conversion = {toml_value(m['conversion'])}",
            f"conversion_steps = {toml_value(steps)}",
            f"conversion_tools = {toml_value(tools)}",
            f"verified_with = {toml_value(verify)}",
            f"preprocessing = {toml_value(m['preprocessing'])}",
            f"input_name = {toml_value(m['input']['name'])}",
            f"input_shape = {toml_value(m['input']['shape'])}",
            f"smoke_input_shape = {toml_value(m['input'].get('smoke_shape', m['input']['shape']))}",
            f"output_name = {toml_value(m['output']['name'])}",
            f"output_shape = {toml_value(m['output']['shape'])}",
            f"output_shape_for_smoke_input = {toml_value(m['output'].get('smoke_shape', m['output']['shape']))}",
            f"output_meaning = {toml_value(m['output'].get('range', ''))}",
            f"reproducible = {toml_value(m.get('reproducible', True))}",
            f"provenance = {toml_value(provenance)}",
        ]
        if f"{m['id']}.reference_source" in facts:
            lines += equivalence_lines(m, fact, path)
        lines.append("")
    names = {m["file"] for m in present} | {"MANIFEST.toml", "SHA256SUMS"}
    for extra in sorted(os.listdir(dist)):
        if extra in names or not os.path.isfile(os.path.join(dist, extra)):
            continue
        path = os.path.join(dist, extra)
        lines += [
            "[[extra]]",
            f"name = {toml_value(extra)}",
            f"size = {os.path.getsize(path)}",
            f"sha256 = {toml_value(file_digest(path))}",
            "",
        ]
    text = "\n".join(lines)
    tomllib.loads(text)  # never write a manifest that does not parse
    with open(os.path.join(dist, "MANIFEST.toml"), "w", encoding="utf-8") as f:
        f.write(text)


def equivalence_lines(m, fact, path):
    """The [file.equivalence] table of a reference file: how the fresh
    conversion of this build was shown to be equivalent to it."""
    p = f"{m['id']}.equivalence"
    tolerance = float(fact(f"{p}_tolerance"))
    if tolerance != m["equivalence_tolerance"]:
        raise UsageError(f"{m['id']}: the equivalence was checked at {tolerance}, models.toml says "
                         f"{m['equivalence_tolerance']}")
    return [
        f"reference_source = {toml_value(fact(m['id'] + '.reference_source'))}",
        "",
        "[file.equivalence]",
        'result = "equivalent"',
        f"fresh_sha256 = {toml_value(fact(p + '_fresh_sha256'))}",
        f"fresh_size = {int(fact(p + '_fresh_size'))}",
        f"same = {toml_value(['ir_version', 'opset_imports', 'inputs', 'outputs', 'initializers', 'nodes'])}",
        f"initializers = {int(fact(p + '_initializers'))}",
        f"nodes_compared = {int(fact(p + '_nodes_compared'))}",
        f"ignored_rule = {toml_value(NOOP_RULE_TEXT)}",
        f"ignored_nodes_reference = {int(fact(p + '_ignored_reference'))}",
        f"ignored_nodes_fresh = {int(fact(p + '_ignored_fresh'))}",
        f"probes = {toml_value(fact(p + '_probes').split())}",
        "# The largest absolute difference over every output value of every probe.",
        f"max_abs_diff = {toml_value(float(fact(p + '_max_abs_diff')))}",
        f"tolerance = {toml_value(tolerance)}",
    ]


# The no-op rule of scripts/lib/equivalence.py, as the manifest states it.
NOOP_RULE_TEXT = (
    "a Reshape whose data input and output have the same fully static shape "
    "and element type after ONNX shape inference (an identity)"
)


def licence_file_name(spdx):
    return f"LICENSE-{spdx}"


def main(argv):
    here = os.path.dirname(os.path.abspath(__file__))
    models_path = os.path.join(here, "..", "..", "models.toml")
    args = list(argv)
    if args[:1] == ["--models"]:
        if len(args) < 2:
            raise UsageError("--models needs a file")
        models_path = args[1]
        args = args[2:]
    if not args:
        raise UsageError("no subcommand (ids, get, check, manifest, licence-file)")
    cmd, rest = args[0], args[1:]
    table, models = load(models_path)
    if cmd == "ids":
        kind = None
        if rest[:1] == ["--kind"] and len(rest) == 2:
            kind = rest[1]
        elif rest:
            raise UsageError("usage: ids [--kind KIND]")
        for m in models:
            if kind is None or m.get("kind") == kind:
                print(m["id"])
        return 0
    if cmd == "get":
        if len(rest) != 2:
            raise UsageError("usage: get ID KEY")
        value = lookup(find(models, rest[0]), rest[1])
        if isinstance(value, list):
            for v in value:
                print(v)
        elif isinstance(value, dict):
            raise UsageError(f"{rest[1]} is a table")
        else:
            print(value)
        return 0
    if cmd == "reproducible":
        if len(rest) != 1:
            raise UsageError("usage: reproducible ID")
        print("yes" if find(models, rest[0]).get("reproducible", True) else "no")
        return 0
    if cmd == "licence-file":
        if len(rest) != 1:
            raise UsageError("usage: licence-file ID")
        print(licence_file_name(find(models, rest[0])["licence"]))
        return 0
    if cmd == "check":
        repo = None
        if rest[:1] == ["--repo"] and len(rest) == 2:
            repo = rest[1]
        elif rest:
            raise UsageError("usage: check [--repo DIR]")
        errors = cmd_check(models, repo)
        for e in errors:
            print(e, file=sys.stderr)
        if errors:
            return 1
        print(f"ok: {len(models)} models")
        return 0
    if cmd == "manifest":
        if len(rest) != 2:
            raise UsageError("usage: manifest DIST FACTS")
        cmd_manifest(table, models, rest[0], rest[1])
        return 0
    raise UsageError(f"unknown subcommand {cmd}")


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except UsageError as e:
        print(f"models.py: {e}", file=sys.stderr)
        sys.exit(2)
