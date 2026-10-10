"""
Hansard IVF parameter tuning
============================

Picks the parameters for the real build instead of guessing them.

Three changes from the probe, all prompted by the v2 run:

  * EMBEDDINGS ARE CACHED. v2 paid twelve minutes to compute the same
    600k vectors twice. Embed once to a .npy, then every tuning run is
    free. Embedding the full 1.7M is ~20 minutes and means tuning
    happens at the real scale rather than extrapolating from 600k —
    which is worth doing, because the v2 sweep showed the curve does
    not behave the way a naive reading of the first two points
    suggested.

  * INVERTED LIST. v2 gathered candidates with torch.isin over the
    whole assignment vector per query. At 1.7M rows and nprobe in the
    hundreds that dominates the runtime and measures nothing useful.
    Candidates now come from a sorted index with offsets, which is
    also how the SQL side will actually work.

  * BYTES TOUCHED. Scan percentage was always a proxy. What the demo
    is really claiming is an IO argument: 3.6% of a 144 MB signature
    columnstore against 3.6% of a 2.6 GB vector store is the same
    recall for two orders of magnitude less data off disk. So measure
    megabytes, not percent.

Phase 1 sweeps nlist, phase 2 sweeps the reranker shortlist at
whichever nlist won. Grid rather than full factorial, because the two
interact weakly and a grid would take all evening.
"""

import os
import time
import numpy as np
import torch
from datasets import load_dataset
from sentence_transformers import SentenceTransformer
from sklearn.metrics import normalized_mutual_info_score

# ----------------------------------------------------------------------
DATASET   = "biglam/hansard_speech"
MODEL     = "BAAI/bge-small-en-v1.5"
MIN_WORDS = 40
N_CORPUS  = None            # None = all ~1.7M; set smaller to rehearse
CACHE     = "hansard_emb.npy"
CACHE_MET = "hansard_meta.npz"

NLIST_MULTS = [8.0, 16.0, 32.0]
# NLIST_MULTS  = [2.0, 4.0, 8.0]
KMEANS_ITERS = 150
CONV_TOL     = 0.0005       # fraction of points still moving

# SHORTLISTS   = [1000, 2000, 4000, "adaptive"]   # adaptive = candidates/20
SHORTLISTS  = [250, 500, 750, 1000]
PROBE_FRACS  = [0.005, 0.01, 0.015, 0.02, 0.03, 0.05, 0.08]
N_QUERIES    = 1_000
TOP_K        = 10
TARGET       = 0.90

DIM      = 384
SIG_BYTES = DIM // 8 + 12   # 6 x BIGINT signature + id, cluster, date
# VEC_BYTES = DIM * 4         # float32 rerank fetch
VEC_BYTES   = DIM * 2        # float16 vector store

DEV = "cuda"


# ----------------------------------------------------------------------
def get_embeddings():
    if os.path.exists(CACHE) and os.path.exists(CACHE_MET):
        print(f"Loading cached embeddings from {CACHE}")
        v = np.load(CACHE)
        m = np.load(CACHE_MET, allow_pickle=True)
        print(f"  {v.shape[0]:,} x {v.shape[1]}  ({v.nbytes/1e9:.2f} GB)")
        return v, list(m["headings"])

    print("No cache. Loading corpus ...")
    ds = load_dataset(DATASET, split="train")
    ds = ds.filter(
        lambda r: r["speech"] and len(r["speech"].split()) >= MIN_WORDS
                  and r["major_heading"],
        num_proc=8,
    )
    print(f"  {len(ds):,} speeches after filter")
    ds = ds.shuffle(seed=42)
    if N_CORPUS:
        ds = ds.select(range(min(N_CORPUS, len(ds))))

    texts = list(ds["speech"])
    headings = list(ds["major_heading"])

    print(f"Embedding {len(texts):,} speeches (one time, then cached) ...")
    t0 = time.time()
    model = SentenceTransformer(MODEL, device=DEV)
    v = model.encode(texts, batch_size=512, normalize_embeddings=True,
                     show_progress_bar=True, convert_to_numpy=True)
    print(f"  {time.time()-t0:.0f}s")

    np.save(CACHE, v)
    np.savez_compressed(CACHE_MET, headings=np.array(headings, dtype=object))
    print(f"  cached to {CACHE} ({v.nbytes/1e9:.2f} GB)")
    return v, headings


def kmeans_pp_init(x, k, gen):
    n = x.shape[0]
    cent = torch.empty(k, x.shape[1], device=x.device, dtype=x.dtype)
    cent[0] = x[torch.randint(n, (1,), generator=gen, device=x.device)]
    best = x @ cent[0]
    for i in range(1, k):
        d2 = (2.0 - 2.0 * best).clamp(min=0)
        cent[i] = x[torch.multinomial(d2 / d2.sum(), 1, generator=gen)]
        best = torch.maximum(best, x @ cent[i])
    return cent


def kmeans(x, k, iters, tol):
    gen = torch.Generator(device=x.device).manual_seed(42)
    t0 = time.time()
    cent = kmeans_pp_init(x, k, gen)
    print(f"    k-means++ init {time.time()-t0:.0f}s")

    n = x.shape[0]
    prev = torch.full((n,), -1, dtype=torch.long, device=x.device)
    chunk = max(1024, int(2e8 // k))          # keep the sim matrix bounded

    for it in range(iters):
        assign = torch.empty(n, dtype=torch.long, device=x.device)
        for s in range(0, n, chunk):
            e = min(s + chunk, n)
            assign[s:e] = (x[s:e] @ cent.T).argmax(dim=1)

        moved = (assign != prev).sum().item()
        prev = assign

        new = torch.zeros_like(cent)
        new.index_add_(0, assign, x)
        counts = torch.bincount(assign, minlength=k)
        nz = counts > 0
        new[nz] = new[nz] / counts[nz].unsqueeze(1)
        new[~nz] = cent[~nz]
        cent = torch.nn.functional.normalize(new, dim=1)

        if moved / n < tol:
            print(f"    converged at iter {it+1} "
                  f"({moved/n:.4%} moving, {(~nz).sum().item()} empty, "
                  f"{time.time()-t0:.0f}s)")
            return cent, assign, time.time() - t0
        if (it + 1) % 25 == 0:
            print(f"    iter {it+1:3d}  {moved/n:.4%} moving")

    print(f"    hit iteration cap at {moved/n:.4%} still moving "
          f"({time.time()-t0:.0f}s)")
    return cent, assign, time.time() - t0


def build_inverted(assign, k):
    """Sorted row ids plus per-cluster offsets. Candidate gathering
    becomes a slice, which is also what the ordered columnstore does."""
    order = torch.argsort(assign)
    counts = torch.bincount(assign, minlength=k)
    offs = torch.zeros(k + 1, dtype=torch.long, device=assign.device)
    offs[1:] = torch.cumsum(counts, 0)
    return order, offs


def exact_topk(x, q_idx, k):
    out = torch.empty(len(q_idx), k, dtype=torch.long, device=x.device)
    for s in range(0, len(q_idx), 32):
        e = min(s + 32, len(q_idx))
        sim = x[q_idx[s:e]] @ x.T
        sim[torch.arange(e - s), q_idx[s:e]] = -2.0
        out[s:e] = sim.topk(k, dim=1).indices
    return out


def evaluate(x, sign, cent, order, offs, q_idx, exact, nprobe, shortlist):
    q = x[q_idx]
    q_sign = sign[q_idx]
    probe = (q @ cent.T).topk(nprobe, dim=1).indices

    hits, scanned, reranked = 0, 0, 0
    for i in range(len(q_idx)):
        cand = torch.cat([order[offs[c]:offs[c + 1]] for c in probe[i]])
        if cand.numel() == 0:
            continue
        scanned += cand.numel()

        m = (max(1000, cand.numel() // 20) if shortlist == "adaptive"
             else shortlist)
        m = min(m, cand.numel())
        reranked += m

        ham = q_sign[i] @ sign[cand].T
        short = cand[ham.topk(m).indices]
        sim = q[i] @ x[short].T
        sim[short == q_idx[i]] = -2.0
        hits += len(set(short[sim.topk(min(TOP_K, m)).indices].tolist())
                    & set(exact[i].tolist()))

    nq = len(q_idx)
    return (hits / (nq * TOP_K),
            scanned / nq,
            reranked / nq)


def mb_per_query(scanned, reranked):
    return (scanned * SIG_BYTES + reranked * VEC_BYTES) / 1e6


def sweep_nprobe(x, sign, cent, order, offs, q_idx, exact, nlist, shortlist):
    """Return the cheapest configuration that clears TARGET recall."""
    best = None
    for f in PROBE_FRACS:
        p = max(1, int(round(f * nlist)))
        rec, scanned, reranked = evaluate(
            x, sign, cent, order, offs, q_idx, exact, p, shortlist)
        mb = mb_per_query(scanned, reranked)
        pct = scanned / x.shape[0] * 100
        print(f"      nprobe {p:>5}  scan {pct:>6.2f}%  "
              f"{mb:>7.1f} MB  recall {rec:.3f}")
        if rec >= TARGET and best is None:
            best = (p, pct, mb, rec)
    return best


# ----------------------------------------------------------------------
if __name__ == "__main__":
    torch.manual_seed(42)
    np.random.seed(42)

    vecs, headings = get_embeddings()
    n = vecs.shape[0]
    x = torch.nn.functional.normalize(torch.from_numpy(vecs).to(DEV), dim=1)

    centre = x.mean(dim=0, keepdim=True)
    sign = torch.sign(x - centre)
    sign[sign == 0] = 1.0

    q_idx = torch.randperm(n, device=DEV)[:N_QUERIES]
    print("\nComputing exact ground truth ...")
    exact = exact_topk(x, q_idx, TOP_K)

    brute_mb = n * VEC_BYTES / 1e6
    print(f"  brute force reads {brute_mb:,.0f} MB per query")

    # ---------------- phase 1: nlist ----------------
    print(f"\n{'='*64}\nPHASE 1 - nlist  (shortlist fixed at 2000)\n{'='*64}")
    p1 = []
    for mult in NLIST_MULTS:
        nlist = int(mult * np.sqrt(n))
        print(f"\n  nlist = {nlist}  ({mult} x sqrt(n))")
        cent, assign, build_s = kmeans(x, nlist, KMEANS_ITERS, CONV_TOL)
        order, offs = build_inverted(assign, nlist)

        sub = np.random.RandomState(0).choice(n, 10_000, replace=False)
        nmi = normalized_mutual_info_score(
            [headings[i] for i in sub], assign.cpu().numpy()[sub])
        print(f"    NMI {nmi:.3f}")

        best = sweep_nprobe(x, sign, cent, order, offs, q_idx, exact,
                            nlist, 2000)
        p1.append((nlist, mult, nmi, build_s, best, cent, assign))
        if best:
            print(f"    -> {best[2]:.1f} MB/query at recall {best[3]:.3f}")
        else:
            print(f"    -> never reached {TARGET}")

    winner = min((r for r in p1 if r[4]), key=lambda r: r[4][2], default=None)
    if winner is None:
        raise SystemExit("No nlist cleared the recall target. Widen "
                         "PROBE_FRACS and retry.")

    nlist, mult, nmi, build_s, best, cent, assign = winner
    order, offs = build_inverted(assign, nlist)
    print(f"\n  best nlist = {nlist} ({mult} x sqrt(n)), "
          f"{best[2]:.1f} MB/query")

    # ---------------- phase 2: shortlist ----------------
    print(f"\n{'='*64}\nPHASE 2 - reranker shortlist (nlist={nlist})"
          f"\n{'='*64}")
    p2 = []
    for sl in SHORTLISTS:
        print(f"\n  shortlist = {sl}")
        b = sweep_nprobe(x, sign, cent, order, offs, q_idx, exact, nlist, sl)
        p2.append((sl, b))
        if b:
            print(f"    -> {b[2]:.1f} MB/query at recall {b[3]:.3f}")

    # ---------------- recommendation ----------------
    print(f"\n{'='*64}\nBUILD PARAMETERS\n{'='*64}")
    ok = [(sl, b) for sl, b in p2 if b]
    if not ok:
        raise SystemExit("No shortlist cleared the target at this nlist.")
    sl, b = min(ok, key=lambda t: t[1][2])
    p, pct, mb, rec = b

    print(f"  corpus      {n:,} speeches")
    print(f"  nlist       {nlist}")
    print(f"  nprobe      {p}")
    print(f"  shortlist   {sl}")
    print(f"  k-means     {build_s:.0f}s on the 5090")
    print(f"  NMI         {nmi:.3f}")
    print()
    print(f"  recall@10   {rec:.3f}")
    print(f"  scan        {pct:.2f}% of rows")
    print(f"  read        {mb:.1f} MB/query vs {brute_mb:,.0f} MB brute force"
          f"  ({brute_mb/mb:.0f}x less)")
    print()
    print(f"  Signature table ~{n * SIG_BYTES / 1e6:,.0f} MB before")
    print(f"  columnstore compression; vector table "
          f"~{n * VEC_BYTES / 1e9:.1f} GB.")
    print("  That gap is the argument — same recall, two orders of")
    print("  magnitude less data off disk. Quote MB, not percent.")
