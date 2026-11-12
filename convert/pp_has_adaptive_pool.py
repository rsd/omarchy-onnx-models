# SPDX-License-Identifier: MIT OR Apache-2.0
"""Tells whether paddle2onnx left an unresolved adaptive pooling: an
AveragePool node whose kernel_shape is [-1, -1]. Prints "yes" or "no".

Usage: python -I pp_has_adaptive_pool.py FILE.onnx
"""
import sys

import onnx

model = onnx.load(sys.argv[1])
found = [
    n.name
    for n in model.graph.node
    if n.op_type == "AveragePool"
    and any(a.name == "kernel_shape" and list(a.ints) == [-1, -1] for a in n.attribute)
]
print("yes" if found else "no")
for name in found:
    print(f"  unresolved AveragePool: {name}", file=sys.stderr)
