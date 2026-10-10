"""
Hansard - export the ministerial post columns
=============================================

The original load dropped three columns that turn out to matter:

    government_posts     e.g. "Minister of State, Home Office"
    opposition_posts     e.g. "Shadow Secretary of State for Health"
    parliamentary_posts  e.g. "Chair, Public Accounts Committee"

Without them you have to infer frontbench status from party, and
that produced a garbage result: the first analysis "found" the
government adopting arguments from John McDonnell, a Labour
backbencher under a Labour government and a serial rebel. Party
membership is not the same as speaking for the government.

This re-runs the same corpus selection and exports just the post
fields keyed by speech_id, so they can be bulk-loaded alongside
what is already there. No re-embedding, no clustering.

MIN_WORDS and SEED must match the original build or the speech_ids
will not line up. The assert catches that.

Takes about three minutes, most of it the flatten.
"""

import os
import time
from datasets import load_dataset

OUT_DIR   = r"C:\SQLData\hansard_load"
DATASET   = "biglam/hansard_speech"
MIN_WORDS = 40
SEED      = 42
N_EXPECT  = 1_700_647

BATCH   = 5000
BUFSIZE = 1 << 22
FS = "\x01"
RS = "\x02"


def clean(s):
    if s is None:
        return ""
    return str(s).replace(FS, " ").replace(RS, " ")


if __name__ == "__main__":
    os.makedirs(OUT_DIR, exist_ok=True)

    print("Replaying corpus selection ...")
    ds = load_dataset(DATASET, split="train")
    ds = ds.filter(
        lambda r: r["speech"] and len(r["speech"].split()) >= MIN_WORDS
                  and r["major_heading"]
    )
    assert len(ds) == N_EXPECT, (
        f"Corpus is {len(ds):,}, expected {N_EXPECT:,}. "
        f"MIN_WORDS or SEED does not match the original build."
    )
    ds = ds.shuffle(seed=SEED)
    print("  flattening ...")
    ds = ds.flatten_indices()

    path = os.path.join(OUT_DIR, "posts.dat")
    print(f"writing {path} ...")
    t0 = time.time()

    i = 0
    with open(path, "w", encoding="utf-8", newline="",
              buffering=BUFSIZE) as f:
        for batch in ds.iter(batch_size=BATCH):
            gov = batch["government_posts"]
            opp = batch["opposition_posts"]
            par = batch["parliamentary_posts"]
            for j in range(len(gov)):
                f.write(FS.join([
                    str(i), clean(gov[j]), clean(opp[j]), clean(par[j])
                ]) + RS)
                i += 1
            if i % 200_000 < BATCH:
                print(f"  {i:>9,}  {i/(time.time()-t0):>8,.0f} rows/sec")

    print(f"  done, {i:,} rows in {time.time()-t0:.0f}s")
    print("\nNow run the BULK INSERT block at the top of "
          "hansard_adoption_v2.sql")
