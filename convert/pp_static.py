# SPDX-License-Identifier: MIT OR Apache-2.0
# A conversion step of scripts/build-models.sh. The release checksums in
# models.toml depend on this logic: change it only together with them.
"""Re-save a Paddle inference model with a static input shape. Usage: in_dir out_dir H W"""
import sys, paddle
paddle.enable_static()
exe = paddle.static.Executor(paddle.CPUPlace())
prog, feeds, fetches = paddle.static.load_inference_model(sys.argv[1] + "/model", exe)
blk = prog.global_block()
blk.var(feeds[0]).desc.set_shape([1, 3, int(sys.argv[3]), int(sys.argv[4])])
for op in blk.ops:
    if op.type in ("feed", "fetch"): continue
    op.desc.infer_shape(blk.desc)
blk._sync_with_cpp()
feed_vars = [blk.var(n) for n in feeds]
paddle.static.save_inference_model(sys.argv[2] + "/model", feed_vars, fetches, exe, program=prog)
print("saved", sys.argv[2])
