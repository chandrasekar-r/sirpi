"""Chunked (block-parallel) gated delta rule for training Qwen3.5's linear-attention layers with mlx-lm.

mlx-lm's training path runs the recurrence one token at a time (`use_kernel=not self.training`), which for 10k+ token
examples allocates hundreds of thousands of Metal buffers and aborts. This is the chunkwise form used by linear-
attention training libraries (WY representation): tokens are processed in blocks of C with matrix products, and only
the T/C block boundaries are sequential. Pure MLX ops, so it is differentiable.

Shapes follow mlx-lm: q, k [B, T, Hk, Dk]; v [B, T, Hv, Dv]; state [B, Hv, Dv, Dk]. q already carries the 1/sqrt(Dk)
readout scale (see normalize_qk).
"""
import mlx.core as mx
import mlx.nn as nn


def _inv_unit_lower(A, C):
    """(I - A)^-1 for strictly lower-triangular A, by recursive 2x2 block inversion.

    For I - A = [[I - A11, 0], [-A21, I - A22]] the inverse is [[X1, 0], [X2 A21 X1, X2]] with X1, X2 the inverses of
    the diagonal blocks. log2(C) levels of batched matmuls: exact, stable (no matrix powers, which overflow float32 when
    keys are similar) and O(C^2 log C) memory instead of the O(C^3) of row-by-row substitution.
    """
    if C == 1:
        return mx.ones(A.shape, dtype=A.dtype)
    h = C // 2
    # Both diagonal blocks are inverted in one recursive call by stacking them on a new leading axis.
    diag = mx.stack([A[..., :h, :h], A[..., h:, h:]], axis=0)
    X = _inv_unit_lower(diag, h)
    X1, X2 = X[0], X[1]
    low = X2 @ A[..., h:, :h] @ X1
    zeros = mx.zeros(X1.shape, dtype=A.dtype)
    top = mx.concatenate([X1, zeros], axis=-1)
    bottom = mx.concatenate([low, X2], axis=-1)
    return mx.concatenate([top, bottom], axis=-2)


def chunked_gated_delta(q, k, v, log_g, beta, state=None, chunk=64):
    B, T, Hk, Dk = q.shape
    Hv, Dv = v.shape[-2:]
    if (r := Hv // Hk) > 1:
        q = mx.repeat(q, r, -2)
        k = mx.repeat(k, r, -2)
    f32 = mx.float32
    # [B, H, T, D]
    q, k, v = (t.astype(f32).transpose(0, 2, 1, 3) for t in (q, k, v))
    log_g = log_g.astype(f32).transpose(0, 2, 1)  # [B, H, T]
    beta = beta.astype(f32).transpose(0, 2, 1)
    C = chunk
    N = (T + C - 1) // C
    pad = N * C - T
    if pad:
        # Padded tokens: k = v = beta = 0 and log_g = 0 leave the state untouched.
        q, k, v = (mx.pad(t, [(0, 0), (0, 0), (0, pad), (0, 0)]) for t in (q, k, v))
        log_g = mx.pad(log_g, [(0, 0), (0, 0), (0, pad)])
        beta = mx.pad(beta, [(0, 0), (0, 0), (0, pad)])
    q = q.reshape(B, Hv, N, C, Dk)
    k = k.reshape(B, Hv, N, C, Dk)
    v = v.reshape(B, Hv, N, C, Dv)
    log_g = log_g.reshape(B, Hv, N, C)
    beta = beta.reshape(B, Hv, N, C)

    k_beta = k * beta[..., None]
    v_beta = v * beta[..., None]
    gc = mx.cumsum(log_g, axis=-1)                      # [B, H, N, C]
    idx = mx.arange(C)
    tril = idx[:, None] >= idx[None, :]
    strict = idx[:, None] > idx[None, :]
    diff = gc[..., :, None] - gc[..., None, :]          # [B, H, N, C, C]
    L = mx.where(tril, mx.exp(mx.where(tril, diff, 0.0)), 0.0)

    A = mx.where(strict, -(k_beta @ k.swapaxes(-1, -2)) * L, 0.0)
    M = _inv_unit_lower(A, C)                           # (I - A)^-1
    value = M @ v_beta                                   # [B, H, N, C, Dv]
    k_cumdecay = M @ (k_beta * mx.exp(gc)[..., None])    # [B, H, N, C, Dk]
    attn_intra = (q @ k.swapaxes(-1, -2)) * L            # [B, H, N, C, C]
    q_decay = q * mx.exp(gc)[..., None]
    k_tail = k * mx.exp(gc[..., -1:] - gc)[..., None]    # decay from each token to chunk end
    g_last = mx.exp(gc[..., -1])                         # [B, H, N]

    if state is None:
        S = mx.zeros((B, Hv, Dk, Dv), dtype=f32)
    else:
        S = state.astype(f32).swapaxes(-1, -2)           # [B, H, Dk, Dv]
    outs = []
    for c in range(N):
        v_new = value[:, :, c] - k_cumdecay[:, :, c] @ S
        outs.append(q_decay[:, :, c] @ S + attn_intra[:, :, c] @ v_new)
        S = S * g_last[:, :, c][..., None, None] + k_tail[:, :, c].swapaxes(-1, -2) @ v_new
    o = mx.stack(outs, axis=2).reshape(B, Hv, N * C, Dv)[:, :, :T]
    return o.transpose(0, 2, 1, 3), S.swapaxes(-1, -2)


def log_decay(A_log, a, dt_bias):
    return -mx.exp(A_log.astype(mx.float32)) * nn.softplus((a + dt_bias).astype(mx.float32))


def patch_mlx_lm(chunk=64):
    """Route qwen3_5 / qwen3_next training forward passes through the chunked recurrence."""
    import mlx_lm.models.gated_delta as gd
    import mlx_lm.models.qwen3_5 as q35

    original = gd.gated_delta_update

    def update(q, k, v, a, b, A_log, dt_bias, state=None, mask=None, *, use_kernel=True,
               lower_bound=None, allow_neg_eigval=False):
        if use_kernel or mask is not None or lower_bound is not None:
            return original(q, k, v, a, b, A_log, dt_bias, state, mask, use_kernel=use_kernel,
                            lower_bound=lower_bound, allow_neg_eigval=allow_neg_eigval)
        beta = mx.sigmoid(b)
        if allow_neg_eigval:
            beta = beta * 2.0
        y, s = chunked_gated_delta(q, k, v, log_decay(A_log, a, dt_bias), beta, state, chunk)
        return y.astype(q.dtype), s

    q35.gated_delta_update = update
    try:
        import mlx_lm.models.qwen3_next as qn
        qn.gated_delta_update = update
    except ImportError:
        pass
