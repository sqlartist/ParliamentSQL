"""
Hansard - phrase coinage and adoption
=====================================

WHY NOT EMBEDDINGS

The semantic approach failed, and it failed for a reason no
amount of tuning fixes. Cross-party pairs came out consistently
FURTHER apart than same-party pairs - no adoption signal in any
lag window - and the reading list showed why. The closest
cross-party pair in the corpus was Heathcoat-Amory arguing
against the fuel duty escalator and Primarolo defending it
eleven weeks later, at distance 0.079.

Embeddings measure what a speech is ABOUT. They do not measure
whether the speaker agrees. Two people on opposite sides of the
same question are near-identical in vector space.

Phrases dodge that completely. If a backbencher coins a
distinctive six-word formulation and a minister uses the same
six words a year later, that is evidence regardless of whether
either of them approved of it. No stance model needed.

HOW

1. Every 6-gram in every speech, hashed to an int64.
2. Sort the lot and count runs. Keep phrases used between 4 and
   300 times - rare enough to be distinctive, common enough that
   reuse is not a coincidence.
3. BURSTINESS filter. Procedural boilerplate ("I beg to move
   that the Bill be") is spread evenly across forty years. A
   coined phrase arrives, spikes, and fades. Measuring the
   concentration of a phrase's occurrences in time separates the
   two, and it is the thing that makes this work at all.
4. Export first and last use with speech ids, and let SQL do the
   politics - who said it first, who said it later, what role
   they held.

MEMORY

~250M 6-grams at 8 bytes is 2 GB for the hashes plus 1 GB for
speech ids. The sort peaks around 8 GB. Fine on 96 GB; would not
be fine on 16.

Runtime maybe 15 minutes, most of it the sort and the second
pass that recovers the phrase text.
"""

import os
import time
import numpy as np
from datasets import load_dataset

OUT_DIR   = r"C:\SQLData\hansard_load"
DATASET   = "biglam/hansard_speech"
MIN_WORDS = 40
SEED      = 42
N_EXPECT  = 1_700_647

NGRAM     = 6          # long enough to be distinctive
MIN_COUNT = 4          # fewer than this and reuse is noise
MAX_COUNT = 300        # more than this and it is boilerplate
MIN_BURST = 0.35       # share of uses falling in one year

FS = "\x01"
RS = "\x02"

# Trailing punctuation only - keeping internal apostrophes so
# "Gentleman's" stays one token.
PUNCT = str.maketrans("", "", '.,;:!?()[]"')


def tokenise(text):
    return [w for w in text.lower().translate(PUNCT).split() if w]


def hash_ngrams(tokens, n):
    """FNV-1a over the joined n-gram. Fast enough in pure Python
    at this scale, and collisions at 64 bits across 250M items
    are rare enough not to matter for a candidate list a human
    will read."""
    out = []
    for i in range(len(tokens) - n + 1):
        h = 0xcbf29ce484222325
        for w in tokens[i:i + n]:
            for b in w.encode():
                h ^= b
                h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
            h ^= 0x20
            h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
        out.append(h)
    return out


def load_corpus():
    print("Loading corpus ...")
    ds = load_dataset(DATASET, split="train")
    ds = ds.filter(
        lambda r: r["speech"] and len(r["speech"].split()) >= MIN_WORDS
                  and r["major_heading"]
    )
    assert len(ds) == N_EXPECT, (
        f"Corpus is {len(ds):,}, expected {N_EXPECT:,}."
    )
    ds = ds.shuffle(seed=SEED)
    print("  flattening ...")
    ds = ds.flatten_indices()
    return ds


def pass_one(ds):
    """Hash every n-gram, keeping the speech index alongside."""
    print(f"\nPass 1: hashing {NGRAM}-grams ...")
    t0 = time.time()
    hash_chunks, id_chunks = [], []
    years = np.zeros(N_EXPECT, dtype=np.int16)

    i = 0
    buf_h, buf_i = [], []
    for batch in ds.iter(batch_size=2000):
        for body, date in zip(batch["speech"], batch["date"]):
            years[i] = int(str(date)[:4])
            hs = hash_ngrams(tokenise(body), NGRAM)
            buf_h.extend(hs)
            buf_i.extend([i] * len(hs))
            i += 1

        if len(buf_h) > 20_000_000:
            hash_chunks.append(np.array(buf_h, dtype=np.uint64))
            id_chunks.append(np.array(buf_i, dtype=np.int32))
            buf_h, buf_i = [], []
            done = sum(len(c) for c in hash_chunks)
            print(f"  {i:>9,} speeches  {done:>12,} ngrams  "
                  f"{time.time()-t0:>5.0f}s")

    if buf_h:
        hash_chunks.append(np.array(buf_h, dtype=np.uint64))
        id_chunks.append(np.array(buf_i, dtype=np.int32))

    H = np.concatenate(hash_chunks); del hash_chunks
    I = np.concatenate(id_chunks);   del id_chunks
    print(f"  {len(H):,} ngrams, {H.nbytes/1e9:.1f} GB "
          f"({time.time()-t0:.0f}s)")
    return H, I, years


def find_candidates(H, I, years):
    """Sort by hash, group into runs, keep the rare-but-repeated
    ones, then score burstiness."""
    print("\nSorting ...")
    t0 = time.time()
    order = np.argsort(H, kind="stable")
    H = H[order]
    I = I[order]
    del order
    print(f"  {time.time()-t0:.0f}s")

    print("Grouping ...")
    uniq, start, counts = np.unique(H, return_index=True,
                                    return_counts=True)
    print(f"  {len(uniq):,} distinct {NGRAM}-grams")

    keep = (counts >= MIN_COUNT) & (counts <= MAX_COUNT)
    print(f"  {keep.sum():,} in the {MIN_COUNT}-{MAX_COUNT} band")

    cand = []
    for k in np.flatnonzero(keep):
        s, c = start[k], counts[k]
        ids = I[s:s + c]
        yrs = years[ids]

        # Burstiness: biggest share of uses in any single year.
        # Boilerplate spreads thin; a coined phrase spikes.
        _, yc = np.unique(yrs, return_counts=True)
        burst = yc.max() / c
        if burst < MIN_BURST:
            continue

        first = ids[np.argmin(yrs)]
        last  = ids[np.argmax(yrs)]
        cand.append((int(uniq[k]), int(c), float(burst),
                     int(first), int(last),
                     int(yrs.min()), int(yrs.max())))

    print(f"  {len(cand):,} survive the burstiness filter")
    return cand


def pass_two(ds, cand):
    """Recover the actual words. We only kept hashes, so walk the
    corpus again looking for the candidate set."""
    print("\nPass 2: recovering phrase text ...")
    t0 = time.time()
    want = {c[0] for c in cand}
    text = {}

    i = 0
    for batch in ds.iter(batch_size=2000):
        for body in batch["speech"]:
            toks = tokenise(body)
            hs = hash_ngrams(toks, NGRAM)
            for j, h in enumerate(hs):
                if h in want and h not in text:
                    text[h] = " ".join(toks[j:j + NGRAM])
            i += 1
        if i % 200_000 == 0:
            print(f"  {i:>9,}  {len(text):,} found  "
                  f"{time.time()-t0:>5.0f}s")
        if len(text) == len(want):
            break

    print(f"  recovered {len(text):,} of {len(want):,}")
    return text


if __name__ == "__main__":
    os.makedirs(OUT_DIR, exist_ok=True)

    ds = load_corpus()
    H, I, years = pass_one(ds)
    cand = find_candidates(H, I, years)
    del H, I

    text = pass_two(ds, cand)

    path = os.path.join(OUT_DIR, "phrase.dat")
    print(f"\nwriting {path} ...")
    n = 0
    with open(path, "w", encoding="utf-8", newline="") as f:
        for h, c, burst, first, last, y0, y1 in cand:
            p = text.get(h)
            if not p:
                continue
            f.write(FS.join([
                str(h), p.replace(FS, " ").replace(RS, " "),
                str(c), f"{burst:.3f}", str(first), str(last),
                str(y0), str(y1)
            ]) + RS)
            n += 1

    print(f"  {n:,} phrases written")
    print("\nNow run hansard_phrases.sql to do the politics.")
