"""Cross-entropy over the 248k-token vocabulary in slices, so long examples never hold full logits in memory."""
import mlx.core as mx
import mlx.nn as nn


def make_chunked_loss(chunk=1024):
    def loss(model, batch, lengths):
        inputs, targets = batch[:, :-1], batch[:, 1:]
        lm = model.language_model if hasattr(model, "language_model") else model
        h = lm.model(inputs)
        head = lm.model.embed_tokens.as_linear if lm.args.tie_word_embeddings else lm.lm_head
        T = targets.shape[1]
        steps = mx.arange(1, T + 1)
        mask = mx.logical_and(steps >= lengths[:, 0:1], steps <= lengths[:, 1:])

        total = mx.array(0.0)
        for s in range(0, T, chunk):
            tt, mm = targets[:, s:s + chunk], mask[:, s:s + chunk]
            # Only the hidden states are differentiated; targets and mask ride along as constants.
            piece = mx.checkpoint(lambda hh, tt=tt, mm=mm: (nn.losses.cross_entropy(head(hh), tt) * mm).astype(mx.float32).sum())
            total = total + piece(h[:, s:s + chunk])
        ntoks = mask.sum()
        return total / ntoks, ntoks
    return loss


def patch_loss(chunk=1024):
    import mlx_lm.lora as lora
    import mlx_lm.tuner.trainer as trainer
    fn = make_chunked_loss(chunk)
    for mod in (trainer, lora):
        for name in ("train", "evaluate"):
            orig = getattr(mod, name, None)
            if orig is None or getattr(orig, "_chunked", False):
                continue
            def wrapped(*a, _orig=orig, **kw):
                kw["loss"] = fn
                return _orig(*a, **kw)
            wrapped._chunked = True
            setattr(mod, name, wrapped)
