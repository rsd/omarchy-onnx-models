# SPDX-License-Identifier: MIT OR Apache-2.0
# A conversion step of scripts/build-models.sh. The release checksums in
# models.toml depend on this logic: change it only together with them.
"""Replace MediaPipe's TFLite custom op Convolution2DTransposeBias (left by tf2onnx)
with standard ONNX ConvTranspose(stride 2) + NHWC transposes. Usage: in.onnx out.onnx"""
import sys, onnx
from onnx import helper, numpy_helper as nh
m = onnx.load(sys.argv[1]); g = m.graph
inits = {i.name: i for i in g.initializer}
new_nodes = []
for n in g.node:
    if n.op_type != "TFL_Convolution2DTransposeBias":
        new_nodes.append(n); continue
    x, w, b = n.input
    W = nh.to_array(inits[w])            # OHWI
    Wt = W.transpose(3, 0, 1, 2).copy()  # I,O,H,W for ONNX ConvTranspose
    wn, bn = w + "_onnx", b + "_onnx"
    g.initializer.extend([nh.from_array(Wt, wn), nh.from_array(nh.to_array(inits[b]).copy(), bn)])
    t1 = n.name + "_nchw"; ct = n.name + "_ct"
    new_nodes += [
        helper.make_node("Transpose", [x], [t1], perm=[0, 3, 1, 2], name=t1),
        helper.make_node("ConvTranspose", [t1, wn, bn], [ct], strides=[2, 2], kernel_shape=list(Wt.shape[2:]), name=ct),
        helper.make_node("Transpose", [ct], [n.output[0]], perm=[0, 2, 3, 1], name=n.name + "_nhwc"),
    ]
del g.node[:]; g.node.extend(new_nodes)
m.opset_import[0].version = max(m.opset_import[0].version, 13)
onnx.checker.check_model(m); onnx.save(m, sys.argv[2]); print("ok", sys.argv[2])
