"""
Hansard IVF viability probe - v2
================================

Changes from v1, all prompted by the v1 run:

  * VERDICT LOGIC WAS WRONG. v1 gated on silhouette score with a
    threshold borrowed from low-dimensional clustering. In 384-d
    normalised embedding space distances concentrate hard, so
    silhouette sits near zero even when the partition is excellent —
    v1 scored +0.001 while NMI against debate headings was 0.608 and
    IVF recall hit 0.907. Silhouette is now reported for interest
    only and the decision rests on recall and NMI.

  * K-MEANS DID NOT CONVERGE. Random init over 400 clusters left
    centroid shift bouncing (0.136, 0.078, 0.155, 0.032, 0.038) —
    that is empty clusters being reseeded repeatedly, churning the
    partition. Now k-means++ init, more iterations, and convergence
    measured on assignment stability rather than centroid drift.

  * END-TO-END PIPELINE RECALL. v1 measured the IVF stage and the
    binary stage separately, which understates the result: in the
    real design the Hamming ranking only ever sees the few percent
    of rows that survived cluster filtering, not the whole corpus.
    This version simulates the actual query path.

  * SCALE SWEEP. Runs the whole thing at several corpus sizes so you
    can see which way the curve moves before committing to 1.7M.

Corpus note: the >=40 word filter leaves ~1.7M of the 2.69M speeches,
so the full build is 2.6 GB of float32 rather than 4.6.
"""

import numpy as np
import torch
from datasets import load_dataset
from sentence_transformers import SentenceTransformer
from sklearn.metrics import silhouette_score, normalized_mutual_info_score

# ----------------------------------------------------------------------
DATASET   = "biglam/hansard_speech"
MODEL     = "BAAI/bge-small-en-v1.5"
MIN_WORDS = 40

# Corpus sizes to sweep. nlist is set per size by NLIST_MULT * sqrt(n);
# the sqrt rule alone was slightly too coarse at 100k.
SWEEP       = [100_000, 300_000, 600_000]
NLIST_MULT  = 2.0

KMEANS_ITERS = 60
N_QUERIES    = 1_000
PROBE_FRACS  = [0.005, 0.01, 0.02, 0.03, 0.05, 0.08, 0.12]   # of nlist
TOP_K        = 10
SHORTLIST    = 1_000      # rows handed to the full-precision reranker

COL_TEXT    = "speech"
COL_HEADING = "major_heading"

DEV = "cuda"


def load_sample(n):
    ds = load_dataset(DATASET, split="train")
    ds = ds.filter(
        lambda r: r[COL_TEXT] and len(r[COL_TEXT].split()) >= MIN_WORDS
                  and r[COL_HEADING],
        num_proc=8,
    )
    print(f"  corpus after filter: {len(ds):,}")
    ds = ds.shuffle(seed=42).select(range(min(n, len(ds))))
    return list(ds[COL_TEXT]), list(ds[COL_HEADING])


def embed(texts):
    model = SentenceTransformer(MODEL, device=DEV)
    v = model.encode(texts, batch_size=512, normalize_embeddings=True,
                     show_progress_bar=True, convert_to_numpy=True)
    return v


def kmeans_pp_init(x, k, gen):
    """k-means++ . Costs k passes over the data but the GPU makes that
    cheap, and it is the difference between a converged partition and
    the churn v1 produced."""
    n = x.shape[0]
    cent = torch.empty(k, x.shape[1], device=x.device, dtype=x.dtype)
    cent[0] = x[torch.randint(n, (1,), generator=gen, device=x.device)]
    # closest-centroid similarity so far; start with just centroid 0
    best = x @ cent[0]
    for i in range(1, k):
        d2 = (2.0 - 2.0 * best).clamp(min=0)      # squared cosine distance
        probs = d2 / d2.sum()
        pick = torch.multinomial(probs, 1, generator=gen)
        cent[i] = x[pick]
        best = torch.maximum(best, x @ cent[i])
    return cent


def kmeans(x, k, iters):
    print(f"  k-means++ init, k={k}")
    gen = torch.Generator(device=x.device).manual_seed(42)
    cent = kmeans_pp_init(x, k, gen)
    n = x.shape[0]
    prev = torch.full((n,), -1, dtype=torch.long, device=x.device)

    for it in range(iters):
        assign = torch.empty(n, dtype=torch.long, device=x.device)
        for s in range(0, n, 16384):
            e = min(s + 16384, n)
            assign[s:e] = (x[s:e] @ cent.T).argmax(dim=1)

        moved = (assign != prev).sum().item()
        prev = assign

        new = torch.zeros_like(cent)
        new.index_add_(0, assign, x)
        counts = torch.bincount(assign, minlength=k)
        # Leave empty clusters where they are rather than reseeding every
        # iteration — the churn was what stopped v1 settling.
        nz = counts > 0
        new[nz] = new[nz] / counts[nz].unsqueeze(1)
        new[~nz] = cent[~nz]
        cent = torch.nn.functional.normalize(new, dim=1)

        if moved / n < 0.001:
            print(f"    converged at iteration {it+1} "
                  f"({moved} points moved, {(~nz).sum().item()} empty)")
            break
        if (it + 1) % 10 == 0:
            print(f"    iter {it+1:3d}  {moved:>7,} points moved "
                  f"({moved/n:.3%})")

    return cent, assign


def exact_topk(x, q_idx, k):
    out = torch.empty(len(q_idx), k, dtype=torch.long, device=x.device)
    for s in range(0, len(q_idx), 128):
        e = min(s + 128, len(q_idx))
        sim = x[q_idx[s:e]] @ x.T
        sim[torch.arange(e - s), q_idx[s:e]] = -2.0
        out[s:e] = sim.topk(k, dim=1).indices
    return out


def pipeline_recall(x, cent, assign, q_idx, exact, nprobe):
    """Simulate the real query path end to end:

        cluster filter  ->  Hamming shortlist  ->  full-precision rerank

    This is the number the demo lives or dies on, and it is strictly
    better than multiplying the two stages measured in isolation,
    because the binary stage only sees post-filter candidates.
    """
    centre = x.mean(dim=0, keepdim=True)
    sign = torch.sign(x - centre)
    sign[sign == 0] = 1.0
    q_sign = sign[q_idx]

    q = x[q_idx]
    order = (q @ cent.T).argsort(dim=1, descending=True)

    hits_ivf, hits_pipe, scanned = 0, 0, 0
    for i in range(len(q_idx)):
        cand = torch.isin(assign, order[i, :nprobe]).nonzero(as_tuple=True)[0]
        if cand.numel() == 0:
            continue
        scanned += cand.numel()
        truth = set(exact[i].tolist())

        # ceiling: what cluster filtering alone leaves reachable
        sim = q[i] @ x[cand].T
        sim[cand == q_idx[i]] = -2.0
        hits_ivf += len(set(cand[sim.topk(min(TOP_K, cand.numel())).indices]
                            .tolist()) & truth)

        # actual path: Hamming shortlist, then rerank at full precision
        ham = q_sign[i] @ sign[cand].T
        m = min(SHORTLIST, cand.numel())
        short = cand[ham.topk(m).indices]
        sim2 = q[i] @ x[short].T
        sim2[short == q_idx[i]] = -2.0
        hits_pipe += len(set(short[sim2.topk(min(TOP_K, m)).indices].tolist())
                         & truth)

    n = x.shape[0]
    return (hits_ivf / (len(q_idx) * TOP_K),
            hits_pipe / (len(q_idx) * TOP_K),
            scanned / (len(q_idx) * n) * 100)


def run(n_sample, texts, headings):
    print(f"\n{'=' * 64}\nCORPUS SIZE {n_sample:,}\n{'=' * 64}")

    vecs = embed(texts[:n_sample])
    x = torch.nn.functional.normalize(
        torch.from_numpy(vecs).to(DEV), dim=1)

    nlist = int(NLIST_MULT * np.sqrt(n_sample))
    cent, assign = kmeans(x, nlist, KMEANS_ITERS)

    sub = np.random.RandomState(0).choice(n_sample, 10_000, replace=False)
    a_cpu = assign.cpu().numpy()
    sil = silhouette_score(vecs[sub], a_cpu[sub], metric="cosine")
    nmi = normalized_mutual_info_score(
        [headings[i] for i in sub], a_cpu[sub])

    print(f"\n  NMI vs debate heading : {nmi:.3f}   <- the structure test")
    print(f"  silhouette            : {sil:+.3f}   "
          f"(near zero in 384-d; ignore)")

    q_idx = torch.randperm(n_sample, device=DEV)[:N_QUERIES]
    exact = exact_topk(x, q_idx, TOP_K)

    print(f"\n  nlist={nlist}, shortlist={SHORTLIST}")
    print(f"\n  {'nprobe':>7} {'% scan':>8} {'IVF only':>10} {'pipeline':>10}")
    print("  " + "-" * 38)

    rows = []
    for f in PROBE_FRACS:
        p = max(1, int(round(f * nlist)))
        r_ivf, r_pipe, pct = pipeline_recall(x, cent, assign, q_idx, exact, p)
        rows.append((p, pct, r_ivf, r_pipe))
        print(f"  {p:>7} {pct:>7.2f}% {r_ivf:>10.3f} {r_pipe:>10.3f}")

    del x, cent, assign
    torch.cuda.empty_cache()
    return nmi, rows


if __name__ == "__main__":
    torch.manual_seed(42)
    np.random.seed(42)

    print("Loading corpus ...")
    texts, headings = load_sample(max(SWEEP))

    summary = []
    for n in SWEEP:
        if n > len(texts):
            break
        nmi, rows = run(n, texts, headings)
        good = [r for r in rows if r[3] >= 0.90]
        summary.append((n, nmi, good[0] if good else None))

    print(f"\n{'=' * 64}\nSUMMARY\n{'=' * 64}")
    print(f"  {'corpus':>9} {'NMI':>6} {'nprobe':>7} {'% scan':>8} "
          f"{'recall':>8}")
    print("  " + "-" * 42)
    for n, nmi, g in summary:
        if g:
            print(f"  {n:>9,} {nmi:>6.3f} {g[0]:>7} {g[1]:>7.2f}% {g[3]:>8.3f}")
        else:
            print(f"  {n:>9,} {nmi:>6.3f}       -        -  <0.90")

    print("\n  Watch the %-scan column across sizes. If it falls as the")
    print("  corpus grows, the advantage widens with scale and the")
    print("  write-up has its headline. If it is flat, the demo still")
    print("  works — it just argues constant-factor rather than")
    print("  asymptotic benefit, which is a weaker but honest claim.")
