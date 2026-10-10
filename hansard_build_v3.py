"""
Hansard IVF - build and load (v3)
=================================

v1 ran at 42 rows/sec. Two wrong diagnoses later, the benchmark found
the real causes, and neither was the writing:

  * num_proc=8 on the filter. Windows has no fork, so every worker
    spawns a fresh interpreter and re-imports the module. Eight copies
    of torch loading, and all row access crossing process boundaries.
    Single-process filtering over 2.7M rows takes about 40 seconds and
    avoids the entire mechanism.

  * shuffle() leaves an indices MAP rather than reordering the data,
    so every subsequent read is a random seek into the Arrow table.
    flatten_indices() materialises the shuffled order once and turns
    the row loop back into a sequential scan.

For reference, the benchmark measured vector formatting and writing at
~24,000 rows/sec. That part was never the problem, which is why the
v2 "fix" of splitting it into two passes changed nothing. The two-pass
structure is kept anyway - freeing 2.6 GB before the text work is
sensible regardless - but it is not what makes this version fast.

Expect: ~2 min clustering, ~2 min flatten, then the writing passes at
a few thousand rows/sec rather than 42.
"""

import gc
import os
import time
import numpy as np
import torch
from datasets import load_dataset

# ----------------------------------------------------------------------
CACHE     = "hansard_emb.npy"
OUT_DIR   = r"C:\SQLData\hansard_load"
DATASET   = "biglam/hansard_speech"
MIN_WORDS = 40
SEED      = 42

NLIST        = 41730
KMEANS_ITERS = 150
CONV_TOL     = 0.0005

BATCH    = 5000
BUFSIZE  = 1 << 22
FS = "\x01"
RS = "\x02"
DEV = "cuda"

VEC_FMT = ",".join(["%.5f"] * 384)


def vec_to_json(v):
    return "[" + (VEC_FMT % tuple(v)) + "]"


def load_corpus(n_expected):
    """No num_proc, and flatten_indices after the shuffle. Both matter
    on Windows; neither matters much on Linux, which is presumably why
    the defaults look reasonable."""
    print("Replaying corpus selection ...")
    t0 = time.time()
    ds = load_dataset(DATASET, split="train")

    ds = ds.filter(
        lambda r: r["speech"] and len(r["speech"].split()) >= MIN_WORDS
                  and r["major_heading"]
    )
    print(f"  filtered to {len(ds):,} rows ({time.time()-t0:.0f}s)")

    assert len(ds) == n_expected, (
        f"Corpus is {len(ds):,} rows but the cache holds {n_expected:,}. "
        f"MIN_WORDS or SEED does not match the run that built the cache."
    )

    ds = ds.shuffle(seed=SEED)
    print("  flattening shuffle into physical order ...")
    t1 = time.time()
    ds = ds.flatten_indices()
    print(f"  flattened ({time.time()-t1:.0f}s)")
    return ds


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
    print(f"\nk-means: k={k}")
    gen = torch.Generator(device=x.device).manual_seed(SEED)
    t0 = time.time()
    cent = kmeans_pp_init(x, k, gen)
    print(f"  init {time.time()-t0:.0f}s")

    n = x.shape[0]
    prev = torch.full((n,), -1, dtype=torch.long, device=x.device)
    chunk = max(1024, int(2e8 // k))

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
            print(f"  converged at iter {it+1} ({time.time()-t0:.0f}s)")
            break
        if (it + 1) % 25 == 0:
            print(f"  iter {it+1:3d}  {moved/n:.4%} moving")

    return cent.cpu().numpy(), assign.cpu().numpy(), counts.cpu().numpy()


def write_vectors(vecs):
    path = os.path.join(OUT_DIR, "speech_vec.dat")
    print(f"\nwriting speech_vec.dat ({len(vecs):,} rows) ...")
    t0 = time.time()
    with open(path, "w", encoding="utf-8", newline="",
              buffering=BUFSIZE) as f:
        for i in range(len(vecs)):
            f.write(f"{i}{FS}{vec_to_json(vecs[i].tolist())}{RS}")
            if (i + 1) % 100_000 == 0:
                el = time.time() - t0
                print(f"  {i+1:>9,}  {(i+1)/el:>7,.0f} rows/sec  {el:>5.0f}s")
    print(f"  done in {time.time()-t0:.0f}s")


def write_text_and_sigs(ds, sigs, assign):
    print("\nwriting speech.dat and speech_sig.dat ...")
    t0 = time.time()
    pid = {}

    def clean(s):
        if s is None:
            return ""
        return str(s).replace(FS, " ").replace(RS, " ")

    f_sp = open(os.path.join(OUT_DIR, "speech.dat"), "w",
                encoding="utf-8", newline="", buffering=BUFSIZE)
    f_sg = open(os.path.join(OUT_DIR, "speech_sig.dat"), "w",
                encoding="utf-8", newline="", buffering=BUFSIZE)

    i = 0
    for batch in ds.iter(batch_size=BATCH):
        bodies   = batch["speech"]
        dates    = batch["date"]
        parties  = batch["party"]
        speakers = batch["speakername"]
        persons  = batch["person_id"]
        majors   = batch["major_heading"]
        minors   = batch["minor_heading"]
        urls     = batch["url"]

        for j in range(len(bodies)):
            d = str(dates[j])[:10]
            p = parties[j]
            if p and p not in pid:
                pid[p] = len(pid) + 1

            f_sp.write(FS.join([
                str(i), d, clean(p), clean(speakers[j]), clean(persons[j]),
                clean(majors[j]), clean(minors[j]), clean(urls[j]),
                clean(bodies[j]),
            ]) + RS)

            s = sigs[i]
            f_sg.write(FS.join([
                str(i), str(int(assign[i])), d, str(pid.get(p, 0)),
                str(s[0]), str(s[1]), str(s[2]),
                str(s[3]), str(s[4]), str(s[5]),
            ]) + RS)
            i += 1

        if i % 100_000 < BATCH:
            el = time.time() - t0
            print(f"  {i:>9,}  {i/el:>7,.0f} rows/sec  {el:>5.0f}s")

    f_sp.close()
    f_sg.close()
    print(f"  done in {time.time()-t0:.0f}s, {len(pid)} parties")

    with open(os.path.join(OUT_DIR, "party.dat"), "w",
              encoding="utf-8", newline="") as f:
        for p, k in pid.items():
            f.write(f"{k}{FS}{p}{RS}")
    return pid


SQL_TEMPLATE = r"""
/*  Generated by hansard_build_v3.py - run against HANSARD.

    Load order matters. Everything goes into heaps with TABLOCK for
    minimal logging, and the ordered columnstore is built afterwards.
    Build the index first and the rows will not be physically sorted,
    which quietly removes the entire point of the exercise.
*/
USE HANSARD;
GO
SET NOCOUNT ON;
GO

DROP TABLE IF EXISTS dbo.speech_sig;
DROP TABLE IF EXISTS dbo.speech_vec;
DROP TABLE IF EXISTS dbo.speech;
DROP TABLE IF EXISTS dbo.centroid;
DROP TABLE IF EXISTS dbo.party;
DROP TABLE IF EXISTS dbo.model_meta;
GO

CREATE TABLE dbo.party (
    party_id SMALLINT NOT NULL, party_name VARCHAR(100) NOT NULL);

CREATE TABLE dbo.speech (
    speech_id INT NOT NULL, speech_date DATE NOT NULL,
    party VARCHAR(100) NULL, speaker_name VARCHAR(200) NULL,
    person_id VARCHAR(50) NULL, major_heading VARCHAR(500) NULL,
    minor_heading VARCHAR(500) NULL, url VARCHAR(500) NULL,
    body VARCHAR(MAX) NULL);

CREATE TABLE dbo.speech_sig (
    speech_id INT NOT NULL, cluster_id INT NOT NULL,
    speech_date DATE NOT NULL, party_id SMALLINT NOT NULL,
    sig0 BIGINT NOT NULL, sig1 BIGINT NOT NULL, sig2 BIGINT NOT NULL,
    sig3 BIGINT NOT NULL, sig4 BIGINT NOT NULL, sig5 BIGINT NOT NULL);

CREATE TABLE dbo.speech_vec (
    speech_id INT NOT NULL, embedding VECTOR(384) NOT NULL);

CREATE TABLE dbo.centroid (
    cluster_id INT NOT NULL, embedding VECTOR(384) NOT NULL,
    row_count INT NOT NULL);

CREATE TABLE dbo.model_meta (
    meta_id INT NOT NULL, centre VECTOR(384) NOT NULL, nlist INT NOT NULL);
GO

BULK INSERT dbo.party      FROM '{d}\party.dat'
  WITH (FIELDTERMINATOR='\x01', ROWTERMINATOR='\x02', CODEPAGE='65001', TABLOCK);
BULK INSERT dbo.speech     FROM '{d}\speech.dat'
  WITH (FIELDTERMINATOR='\x01', ROWTERMINATOR='\x02', CODEPAGE='65001', TABLOCK);
BULK INSERT dbo.speech_sig FROM '{d}\speech_sig.dat'
  WITH (FIELDTERMINATOR='\x01', ROWTERMINATOR='\x02', CODEPAGE='65001', TABLOCK);
BULK INSERT dbo.speech_vec FROM '{d}\speech_vec.dat'
  WITH (FIELDTERMINATOR='\x01', ROWTERMINATOR='\x02', CODEPAGE='65001', TABLOCK);
BULK INSERT dbo.centroid   FROM '{d}\centroid.dat'
  WITH (FIELDTERMINATOR='\x01', ROWTERMINATOR='\x02', CODEPAGE='65001', TABLOCK);
BULK INSERT dbo.model_meta FROM '{d}\centre.dat'
  WITH (FIELDTERMINATOR='\x01', ROWTERMINATOR='\x02', CODEPAGE='65001', TABLOCK);
GO

SELECT speeches = (SELECT COUNT(*) FROM dbo.speech),
       sigs     = (SELECT COUNT(*) FROM dbo.speech_sig),
       vectors  = (SELECT COUNT(*) FROM dbo.speech_vec),
       clusters = (SELECT COUNT(*) FROM dbo.centroid);
GO

ALTER TABLE dbo.party      ADD CONSTRAINT pk_party    PRIMARY KEY (party_id);
ALTER TABLE dbo.model_meta ADD CONSTRAINT pk_meta     PRIMARY KEY (meta_id);
ALTER TABLE dbo.centroid   ADD CONSTRAINT pk_centroid PRIMARY KEY (cluster_id);
ALTER TABLE dbo.speech     ADD CONSTRAINT pk_speech   PRIMARY KEY (speech_id);
ALTER TABLE dbo.speech_vec ADD CONSTRAINT pk_vec      PRIMARY KEY (speech_id);
GO

CREATE CLUSTERED COLUMNSTORE INDEX ccsi_speech_sig
    ON dbo.speech_sig ORDER (cluster_id);
GO

SELECT rg.row_group_id, rg.total_rows, rg.state_desc,
       rg.size_in_bytes/1024/1024 AS mb
FROM sys.dm_db_column_store_row_group_physical_stats rg
WHERE rg.object_id = OBJECT_ID('dbo.speech_sig')
ORDER BY rg.row_group_id;
GO
"""


if __name__ == "__main__":
    if not os.path.exists(CACHE):
        raise SystemExit(f"{CACHE} not found - run hansard_tune.py first.")
    os.makedirs(OUT_DIR, exist_ok=True)

    print(f"Loading {CACHE} ...")
    vecs = np.load(CACHE)
    n = vecs.shape[0]
    print(f"  {n:,} x {vecs.shape[1]}")

    ds = load_corpus(n)

    x = torch.nn.functional.normalize(torch.from_numpy(vecs).to(DEV), dim=1)
    cent, assign, counts = kmeans(x, NLIST, KMEANS_ITERS, CONV_TOL)
    del x
    torch.cuda.empty_cache()
    print(f"\n  cluster sizes: min {counts.min()}, "
          f"median {int(np.median(counts))}, max {counts.max()}")

    centre = vecs.mean(axis=0)
    bits = (vecs > centre).astype(np.uint8)
    sigs = np.packbits(bits, axis=1).view(">i8")
    del bits
    print("signatures packed")

    write_vectors(vecs)
    del vecs
    gc.collect()
    print("  embedding array released")

    write_text_and_sigs(ds, sigs, assign)

    with open(os.path.join(OUT_DIR, "centroid.dat"), "w",
              encoding="utf-8", newline="", buffering=BUFSIZE) as f:
        for c in range(len(cent)):
            f.write(f"{c}{FS}{vec_to_json(cent[c].tolist())}"
                    f"{FS}{int(counts[c])}{RS}")

    np.save(os.path.join(OUT_DIR, "centre.npy"), centre)
    with open(os.path.join(OUT_DIR, "centre.dat"), "w",
              encoding="utf-8", newline="") as f:
        f.write(f"1{FS}{vec_to_json(centre.tolist())}{FS}{NLIST}{RS}")

    with open(os.path.join(OUT_DIR, "load.sql"), "w", encoding="utf-8") as f:
        f.write(SQL_TEMPLATE.format(d=OUT_DIR))

    print(f"\nWritten to {OUT_DIR}")
    print("  Run load.sql in SSMS against HANSARD.")
    print("  KEEP centre.npy - query signatures are meaningless without it.")
