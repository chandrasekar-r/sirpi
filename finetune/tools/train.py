"""mlx_lm.lora with the chunked gated-delta recurrence patched in (see chunked_gdn.py). Same CLI as mlx_lm.lora."""
import os, sys
sys.path.insert(0, os.path.dirname(__file__))
from chunked_gdn import patch_mlx_lm
patch_mlx_lm(chunk=int(os.environ.get("GDN_CHUNK", "64")))
from chunked_loss import patch_loss
patch_loss(chunk=int(os.environ.get("LOSS_CHUNK", "1024")))
from mlx_lm.lora import main
main()
