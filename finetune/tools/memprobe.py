import sys, os, time
sys.path.insert(0, os.path.dirname(__file__))
import mlx.core as mx, mlx.nn as nn
from chunked_gdn import patch_mlx_lm; patch_mlx_lm(chunk=int(os.environ.get("GDN_CHUNK","64")))
from chunked_loss import make_chunked_loss
from mlx_lm import load
from mlx_lm.tuner.utils import linear_to_lora_layers
model, tok = load(os.environ.get("MODEL", "../mlx-bf16"))
model.freeze()
linear_to_lora_layers(model, -1, {"rank": 8, "scale": 20.0, "dropout": 0.0})
model.train()
for layer in model.language_model.model.layers:
    layer.__call__  # noqa
from mlx_lm.tuner.trainer import grad_checkpoint
grad_checkpoint(model.language_model.model.layers[0])
loss = make_chunked_loss(1024)
vg = nn.value_and_grad(model, loss)
for L in [int(x) for x in sys.argv[1:]]:
    mx.reset_peak_memory(); mx.clear_cache()
    batch = mx.random.randint(0, 1000, (1, L + 1))
    lengths = mx.array([[1, L]])
    t = time.time()
    (lv, n), g = vg(model, batch, lengths)
    mx.eval(lv, g)
    print(f"L={L} loss={lv.item():.2f} peak={mx.get_peak_memory()/1e9:.1f} GB  {time.time()-t:.1f}s", flush=True)
