# SPDX-License-Identifier: MIT OR Apache-2.0
# A conversion step of scripts/build-models.sh. The release checksums in
# models.toml depend on this logic: change it only together with them.
"""Fix paddle2onnx adaptive AveragePool (kernel -1) by fixing the input shape and
computing kernel=stride=in/out. Usage: model_dir in.onnx out.onnx H W"""
import sys, paddle, onnx
from onnx import helper, shape_inference
paddle.enable_static()
exe = paddle.static.Executor(paddle.CPUPlace())
prog, _, _ = paddle.static.load_inference_model(sys.argv[1] + "/model", exe)
outs = [op.attr("ksize") for op in prog.global_block().ops if op.type == "pool2d" and op.attr("adaptive") and op.attr("ksize") != [1, 1]]
H, W = int(sys.argv[4]), int(sys.argv[5])
m = onnx.load(sys.argv[2])
d = m.graph.input[0].type.tensor_type.shape.dim
for dim, v in zip(d, [1, 3, H, W]): dim.ClearField("dim_param"); dim.dim_value = v
def ints(n, name):  # an attribute by its name, never by its position
    return next((list(a.ints) for a in n.attribute if a.name == name), None)
bad = [n for n in m.graph.node if n.op_type == "AveragePool" and ints(n, "kernel_shape") == [-1, -1]]
assert len(bad) == len(outs), (len(bad), outs)
for n, o in zip(bad, outs):
    inf = shape_inference.infer_shapes(m)
    shapes = {vi.name: [x.dim_value for x in vi.type.tensor_type.shape.dim] for vi in list(inf.graph.value_info) + list(inf.graph.input)}
    s = shapes[n.input[0]]; k = [s[2] // o[0], s[3] // o[1]]
    assert s[2] % o[0] == 0 and s[3] % o[1] == 0, (s, o)
    for a in n.attribute:
        if a.name in ("kernel_shape", "strides"): del a.ints[:]; a.ints.extend(k)
    print(n.name, s, "->", o, "k", k)
onnx.checker.check_model(m); onnx.save(m, sys.argv[3])
