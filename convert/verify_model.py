# SPDX-License-Identifier: MIT OR Apache-2.0
"""Checks one release file against its entry in models.toml: onnx.checker, the
opset of the default domain (ai.onnx) against `opset`, the input and output
names and declared shapes (a named dimension must be dynamic), and a CPU
smoke inference with ONNX Runtime on a deterministic
synthetic input whose outputs must be finite, of the expected shape and in
[0, 1].

With --summary, it also writes a JSON summary of the file, the input of the
equivalence check (scripts/lib/equivalence.py, standard library only) that
compares a fresh conversion with a supplied reference file:

  sha256, size, ir_version, opset_imports
  inputs, outputs        graph inputs (initializers excluded) and outputs:
                         name, element type, dimensions (an int, or the name
                         of a dynamic dimension)
  initializers           one entry per initializer, names left out: element
                         type, dimensions and the SHA-256 of the values as
                         little-endian bytes, sorted (a multiset)
  nodes                  one entry per node, names left out: domain, op
                         type, the attributes (a tensor attribute by its
                         digest) and "noop": true for a Reshape whose data
                         input and output have the same fully static shape
                         after ONNX shape inference (an identity on the data)
  probes                 the outputs of ONNX Runtime (CPU, one thread) on the
                         deterministic inputs of probe_inputs(), as float32
                         little-endian bytes in base64

Usage: python -I verify_model.py MODELS_TOML ID FILE [--summary OUT.json]
Runs in the verify environment (requirements/verify.txt). Exit 0 on success.
"""
import base64
import hashlib
import json
import sys
import tomllib

import numpy as np
import onnx
import onnx.helper
import onnx.numpy_helper
import onnx.shape_inference
import onnxruntime as ort

TOL = 1e-5


def fail(msg):
    print(f"verify: {msg}", file=sys.stderr)
    sys.exit(1)


def dims(value_info):
    out = []
    for d in value_info.type.tensor_type.shape.dim:
        if d.HasField("dim_value"):
            out.append(d.dim_value)
        elif d.HasField("dim_param") and d.dim_param:
            out.append(None)  # dynamic
        else:
            out.append(None)
    return out


def check_io(kind, vi, spec):
    if vi.name != spec["name"]:
        fail(f"{kind} name {vi.name!r}, expected {spec['name']!r}")
    got = dims(vi)
    want = spec["shape"]
    if len(got) != len(want):
        fail(f"{kind} rank {len(got)}, expected {len(want)}")
    for i, (g, w) in enumerate(zip(got, want)):
        if isinstance(w, str):
            if g is not None:
                fail(f"{kind} dimension {i} is {g}, expected dynamic ({w})")
        elif g != w:
            fail(f"{kind} dimension {i} is {g}, expected {w}")


def ramp_input(shape, lo, hi, step=7919, period=1009):
    """A deterministic ramp over [lo, hi], folded so that neighbouring values
    differ (no random generator, no seed)."""
    n = int(np.prod(shape))
    ramp = (np.arange(n, dtype=np.float64) * step % period) / (period - 1)
    return (lo + (hi - lo) * ramp).astype(np.float32).reshape(shape)


def portrait_input(shape, lo, hi, cx, scale, background, skin, shirt):
    """A flat synthetic head-and-shoulders picture (an ellipse over a widening
    torso) in the model's layout and value range, or None when the shape is
    not a 3-channel image (NHWC or NCHW). It makes a segmentation model
    answer with a full-range matte, which the ramps and constants do not."""
    if len(shape) != 4 or not (shape[3] == 3 or shape[1] == 3):
        return None
    nhwc = shape[3] == 3
    h, w = (shape[1], shape[2]) if nhwc else (shape[2], shape[3])
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float64)
    img = np.empty((h, w, 3), dtype=np.float64)
    img[:] = background
    u = h / 144.0
    torso = (yy > 78 * u) & (np.abs(xx - cx * w) < 40 * scale * u + (yy - 78 * u) * 0.8)
    head = ((xx - cx * w) / (22 * scale * u)) ** 2 + ((yy - 50 * u) / (28 * scale * u)) ** 2 <= 1
    img[torso] = shirt
    img[head] = skin
    if not nhwc:
        img = img.transpose(2, 0, 1)
    return (lo + (hi - lo) * img).astype(np.float32).reshape(shape)


def probe_inputs(shape, lo, hi):
    """The deterministic inputs of the equivalence probes: the smoke input
    first, then two synthetic portraits (for an image input), other ramps and
    constants over the value range."""
    n = int(np.prod(shape))
    linear = np.linspace(lo, hi, n, dtype=np.float64).astype(np.float32).reshape(shape)
    probes = [
        ("smoke", ramp_input(shape, lo, hi)),
        ("portrait-centre", portrait_input(shape, lo, hi, 0.5, 1.0,
                                           (0.2, 0.3, 0.25), (0.85, 0.65, 0.55), (0.1, 0.2, 0.6))),
        ("portrait-left", portrait_input(shape, lo, hi, 0.3125, 1.3,
                                         (0.9, 0.9, 0.85), (0.6, 0.45, 0.35), (0.7, 0.1, 0.1))),
        ("ramp-104729-997", ramp_input(shape, lo, hi, 104729, 997)),
        ("linear", linear),
        ("low", np.full(shape, lo, dtype=np.float32)),
        ("middle", np.full(shape, (lo + hi) / 2, dtype=np.float32)),
        ("high", np.full(shape, hi, dtype=np.float32)),
    ]
    return [(name, x) for name, x in probes if x is not None]


def le_bytes(array):
    return np.ascontiguousarray(array).astype(array.dtype.newbyteorder("<"), copy=False).tobytes()


def attribute_summary(a):
    kind = onnx.AttributeProto.AttributeType.Name(a.type)
    if a.type == onnx.AttributeProto.TENSOR:
        value = tensor_digest(a.t)
    elif a.type == onnx.AttributeProto.TENSORS:
        value = [tensor_digest(t) for t in a.tensors]
    elif a.type in (onnx.AttributeProto.GRAPH, onnx.AttributeProto.GRAPHS):
        fail(f"attribute {a.name}: subgraphs are not summarised")
    else:
        value = onnx.helper.get_attribute_value(a)
        if isinstance(value, bytes):
            value = value.decode("utf-8", "replace")
        elif isinstance(value, list):
            value = [v.decode("utf-8", "replace") if isinstance(v, bytes) else v for v in value]
    return [a.name, kind, value]


def tensor_digest(t):
    array = onnx.numpy_helper.to_array(t)
    return {
        "type": onnx.TensorProto.DataType.Name(t.data_type),
        "dims": list(t.dims),
        "sha256": hashlib.sha256(le_bytes(array)).hexdigest(),
    }


def io_summary(vi):
    t = vi.type.tensor_type
    return {
        "name": vi.name,
        "type": onnx.TensorProto.DataType.Name(t.elem_type),
        "dims": [d.dim_value if d.HasField("dim_value") else (d.dim_param or None) for d in t.shape.dim],
    }


def static_shapes(model):
    """The fully static shapes ONNX shape inference finds, by value name."""
    inferred = onnx.shape_inference.infer_shapes(model, strict_mode=True, data_prop=True)
    shapes = {}
    for vi in list(inferred.graph.value_info) + list(inferred.graph.input) + list(inferred.graph.output):
        t = vi.type.tensor_type
        if t.HasField("shape") and all(d.HasField("dim_value") for d in t.shape.dim):
            shapes[vi.name] = (t.elem_type, tuple(d.dim_value for d in t.shape.dim))
    return shapes


def summary(path, model, spec, shape, lo, hi):
    with open(path, "rb") as f:
        data = f.read()
    shapes = static_shapes(model)
    nodes = []
    for n in model.graph.node:
        noop = (
            n.domain in ("", "ai.onnx") and n.op_type == "Reshape"
            and n.input[0] in shapes and n.output[0] in shapes
            and shapes[n.input[0]] == shapes[n.output[0]]
        )
        nodes.append({
            "domain": n.domain or "ai.onnx",
            "op_type": n.op_type,
            "attributes": sorted((attribute_summary(a) for a in n.attribute), key=lambda x: x[0]),
            "noop": noop,
        })
    inits = {i.name for i in model.graph.initializer}
    opts = ort.SessionOptions()
    opts.intra_op_num_threads = 1
    opts.inter_op_num_threads = 1
    sess = ort.InferenceSession(path, opts, providers=["CPUExecutionProvider"])
    probes = []
    for name, x in probe_inputs(shape, lo, hi):
        (y,) = sess.run(None, {spec["input"]["name"]: x})
        y = np.asarray(y, dtype=np.float32)
        probes.append({
            "name": name,
            "shape": list(y.shape),
            "float32_le_base64": base64.b64encode(le_bytes(y)).decode("ascii"),
        })
    return {
        "summary_schema": 1,
        # Names the rule that sets "noop"; scripts/lib/equivalence.py accepts
        # only the rule it documents.
        "noop_rule": "reshape-same-static-shape",
        "file": spec["file"],
        "sha256": hashlib.sha256(data).hexdigest(),
        "size": len(data),
        "ir_version": model.ir_version,
        "opset_imports": {(o.domain or "ai.onnx"): o.version for o in model.opset_import},
        "inputs": [io_summary(i) for i in model.graph.input if i.name not in inits],
        "outputs": [io_summary(o) for o in model.graph.output],
        "initializers": sorted(
            (tensor_digest(i) for i in model.graph.initializer),
            key=lambda d: (d["type"], d["dims"], d["sha256"]),
        ),
        "nodes": nodes,
        "probes": probes,
        "tools": {"onnx": onnx.__version__, "onnxruntime": ort.__version__},
    }


def main():
    args = sys.argv[1:]
    summary_out = None
    if len(args) == 5 and args[3] == "--summary":
        summary_out = args[4]
        args = args[:3]
    if len(args) != 3:
        fail("usage: verify_model.py MODELS_TOML ID FILE [--summary OUT.json]")
    with open(args[0], "rb") as f:
        table = tomllib.load(f)
    spec = next((m for m in table["models"] if m["id"] == args[1]), None)
    if spec is None:
        fail(f"unknown id {args[1]}")
    path = args[2]

    onnx.checker.check_model(path, full_check=True)
    model = onnx.load(path)
    opsets = {(o.domain or "ai.onnx"): o.version for o in model.opset_import}
    if opsets.get("ai.onnx") != spec["opset"]:
        fail(f"opset {opsets.get('ai.onnx')} (ai.onnx), expected {spec['opset']}")
    inits = {i.name for i in model.graph.initializer}
    inputs = [i for i in model.graph.input if i.name not in inits]
    if len(inputs) != 1 or len(model.graph.output) != 1:
        fail(f"{len(inputs)} inputs and {len(model.graph.output)} outputs, expected 1 and 1")
    check_io("input", inputs[0], spec["input"])
    check_io("output", model.graph.output[0], spec["output"])

    shape = spec["input"].get("smoke_shape", spec["input"]["shape"])
    lo, hi = spec["input"]["value_range"]
    x = ramp_input(shape, lo, hi)

    sess = ort.InferenceSession(path, providers=["CPUExecutionProvider"])
    (y,) = sess.run(None, {spec["input"]["name"]: x})
    want = spec["output"].get("smoke_shape", spec["output"]["shape"])
    if list(y.shape) != want:
        fail(f"smoke output shape {list(y.shape)}, expected {want}")
    if not np.all(np.isfinite(y)):
        fail("smoke output is not finite")
    if y.min() < -TOL or y.max() > 1 + TOL:
        fail(f"smoke output outside [0, 1]: [{y.min()}, {y.max()}]")
    print(f"ok {spec['file']}: input {shape} -> output {list(y.shape)}, "
          f"values in [{y.min():.4f}, {y.max():.4f}], mean {y.mean():.4f} "
          f"(onnx {onnx.__version__}, onnxruntime {ort.__version__}, CPU)")
    if summary_out is not None:
        with open(summary_out, "w", encoding="utf-8") as f:
            json.dump(summary(path, model, spec, shape, lo, hi), f, sort_keys=True)
            f.write("\n")
        print(f"summary of {spec['file']} written")


if __name__ == "__main__":
    main()
