"""
Hansard IVF - cluster renumbering and partitioned rebuild
=========================================================

THE PROBLEM

The first load produced two rowgroups of ~1M rows each. Rowgroup
elimination works per rowgroup, so with 41,730 clusters spread over
two of them, any probe set hits both and nothing is ever skipped.

The obvious fix - partition the table so there are more, smaller
rowgroups - does not work on its own, and it took me a moment to see
why. k-means hands out cluster ids in arbitrary order. Cluster 7 and
cluster 30,000 may be neighbours in embedding space. So the 417
clusters nearest a query are scattered uniformly across the whole id
range, and slicing that range into partitions just means every probe
touches nearly all of them. Sorting by cluster_id sorts by a number
with no spatial meaning.

THE FIX

Make the id mean something. Cluster the 41,730 centroids into 64
super-clusters, then renumber so that clusters close together in
embedding space get adjacent ids. A probe set then lands in a handful
of contiguous ranges, partitions align with regions of meaning, and
elimination finally has something to eliminate.

That is two-level IVF, and it maps onto storage cleanly:

    super-cluster  ->  partition  ->  rowgroup
    cluster        ->  sort order within it

Outputs into OUT_DIR:

    remap.dat     old_cluster_id -> new_cluster_id, super_id
    rebuild.sql   partition scheme, rebuild, ordered CCI

Run rebuild.sql after this. It rebuilds speech_sig and centroid in
place; speech, speech_vec and model_meta are untouched.
"""

import os
import time
import numpy as np
import torch

# ----------------------------------------------------------------------
OUT_DIR  = r"C:\SQLData\hansard_load"
NLIST    = 41730
NSUPER   = 64          # super-clusters == partitions
ITERS    = 100
SEED     = 42
DEV      = "cuda"

FS = "\x01"
RS = "\x02"


def read_centroids(path):
    """centroid.dat is cluster_id FS [json vector] FS row_count RS."""
    print(f"Reading {path} ...")
    with open(path, "r", encoding="utf-8") as f:
        raw = f.read()
    rows = [r for r in raw.split(RS) if r]
    cent = np.zeros((len(rows), 384), dtype=np.float32)
    counts = np.zeros(len(rows), dtype=np.int64)
    for r in rows:
        cid, vec, cnt = r.split(FS)
        cent[int(cid)] = np.fromstring(vec.strip("[]"), sep=",")
        counts[int(cid)] = int(cnt)
    print(f"  {len(rows):,} centroids")
    return cent, counts


def kmeans(x, k, iters):
    """Plain Lloyd's with k-means++ init. Only 41,730 points here, so
    this is seconds rather than minutes."""
    gen = torch.Generator(device=x.device).manual_seed(SEED)
    n = x.shape[0]

    cent = torch.empty(k, x.shape[1], device=x.device, dtype=x.dtype)
    cent[0] = x[torch.randint(n, (1,), generator=gen, device=x.device)]
    best = x @ cent[0]
    for i in range(1, k):
        d2 = (2.0 - 2.0 * best).clamp(min=0)
        cent[i] = x[torch.multinomial(d2 / d2.sum(), 1, generator=gen)]
        best = torch.maximum(best, x @ cent[i])

    prev = torch.full((n,), -1, dtype=torch.long, device=x.device)
    for it in range(iters):
        assign = (x @ cent.T).argmax(dim=1)
        if (assign == prev).all():
            print(f"  converged at iteration {it+1}")
            break
        prev = assign
        new = torch.zeros_like(cent)
        new.index_add_(0, assign, x)
        c = torch.bincount(assign, minlength=k)
        nz = c > 0
        new[nz] = new[nz] / c[nz].unsqueeze(1)
        new[~nz] = cent[~nz]
        cent = torch.nn.functional.normalize(new, dim=1)

    return cent.cpu().numpy(), assign.cpu().numpy()


def build_remap(cent, counts):
    """Assign each cluster to a super-cluster, then renumber so that
    ids run through one super-cluster before starting the next. Within
    a super-cluster the order does not much matter - sorted by distance
    to the super-centroid, which keeps the tightest clusters adjacent."""
    x = torch.nn.functional.normalize(
        torch.from_numpy(cent).to(DEV), dim=1)

    print(f"\nSuper-clustering {len(cent):,} centroids into {NSUPER} ...")
    t0 = time.time()
    super_cent, super_assign = kmeans(x, NSUPER, ITERS)
    print(f"  {time.time()-t0:.0f}s")

    sc = torch.from_numpy(super_cent).to(DEV)
    sc = torch.nn.functional.normalize(sc, dim=1)
    sim_to_own = (x * sc[torch.from_numpy(super_assign).to(DEV)]).sum(1)
    sim = sim_to_own.cpu().numpy()

    order = np.lexsort((-sim, super_assign))     # super asc, then tightest
    new_id = np.empty(len(cent), dtype=np.int64)
    new_id[order] = np.arange(len(cent))

    sizes = np.bincount(super_assign, minlength=NSUPER)
    rows = np.zeros(NSUPER, dtype=np.int64)
    for c in range(len(cent)):
        rows[super_assign[c]] += counts[c]

    print(f"\n  clusters per super : min {sizes.min()}, "
          f"median {int(np.median(sizes))}, max {sizes.max()}")
    print(f"  rows per super     : min {rows.min():,}, "
          f"median {int(np.median(rows)):,}, max {rows.max():,}")
    if rows.max() > 4 * np.median(rows):
        print("  WARNING: lopsided. One partition holds far more rows")
        print("  than the rest, and probing it will scan more than the")
        print("  tuning predicted. Consider raising NSUPER.")

    return new_id, super_assign, order


def write_outputs(new_id, super_assign, order):
    os.makedirs(OUT_DIR, exist_ok=True)

    path = os.path.join(OUT_DIR, "remap.dat")
    with open(path, "w", encoding="utf-8", newline="") as f:
        for old in range(len(new_id)):
            f.write(f"{old}{FS}{new_id[old]}{FS}"
                    f"{super_assign[old]}{RS}")
    print(f"\n  wrote {path}")

    # Partition boundaries: the new id at which each super-cluster
    # starts. RANGE LEFT, so the boundary value is the last id of the
    # partition below it.
    bounds = []
    for s in range(1, NSUPER):
        first = np.searchsorted(super_assign[order], s)
        bounds.append(int(first) - 1)

    sql = SQL_TEMPLATE.format(
        d=OUT_DIR,
        bounds=",\n        ".join(str(b) for b in bounds),
        nparts=NSUPER,
    )
    p = os.path.join(OUT_DIR, "rebuild.sql")
    with open(p, "w", encoding="utf-8") as f:
        f.write(sql)
    print(f"  wrote {p}")


SQL_TEMPLATE = r"""
/*  Generated by hansard_renumber.py - run against HANSARD.

    Renumbers clusters so that spatial neighbours get adjacent ids,
    then rebuilds speech_sig partitioned on the new id. Partition
    boundaries fall on super-cluster edges, so each partition holds
    one coherent region of embedding space and becomes its own
    rowgroup.

    speech, speech_vec and model_meta are not touched.
*/
USE HANSARD;
GO
SET NOCOUNT ON;
GO

DROP TABLE IF EXISTS dbo.cluster_remap;
CREATE TABLE dbo.cluster_remap (
    old_id   INT NOT NULL,
    new_id   INT NOT NULL,
    super_id INT NOT NULL);
GO

BULK INSERT dbo.cluster_remap FROM '{d}\remap.dat'
  WITH (FIELDTERMINATOR='0x01', ROWTERMINATOR='0x02',
        CODEPAGE='65001', TABLOCK);
GO

ALTER TABLE dbo.cluster_remap ADD CONSTRAINT pk_remap PRIMARY KEY (old_id);
CREATE INDEX ix_remap_new ON dbo.cluster_remap (new_id);
GO

/*  Partition function and scheme. {nparts} partitions, boundaries on
    super-cluster edges.                                             */
IF EXISTS (SELECT 1 FROM sys.partition_schemes WHERE name = 'ps_cluster')
    DROP PARTITION SCHEME ps_cluster;
IF EXISTS (SELECT 1 FROM sys.partition_functions WHERE name = 'pf_cluster')
    DROP PARTITION FUNCTION pf_cluster;
GO

CREATE PARTITION FUNCTION pf_cluster (INT) AS RANGE LEFT FOR VALUES (
        {bounds}
);
GO
CREATE PARTITION SCHEME ps_cluster
    AS PARTITION pf_cluster ALL TO ([PRIMARY]);
GO

/*  Rebuild speech_sig with renumbered clusters, on the scheme.  */
DROP TABLE IF EXISTS dbo.speech_sig_new;
GO

SELECT s.speech_id,
       cluster_id = r.new_id,
       s.speech_date,
       s.party_id,
       s.sig0, s.sig1, s.sig2, s.sig3, s.sig4, s.sig5
INTO dbo.speech_sig_new
FROM dbo.speech_sig s
JOIN dbo.cluster_remap r ON r.old_id = s.cluster_id;
GO

/*  Heap on the partition scheme, then the ordered columnstore. The
    ORDER clause sorts within each partition, which is all that is
    needed now that neighbouring clusters have neighbouring ids.   */
CREATE CLUSTERED COLUMNSTORE INDEX ccsi_speech_sig_new
    ON dbo.speech_sig_new
    ORDER (cluster_id)
    ON ps_cluster (cluster_id);
GO

DROP TABLE dbo.speech_sig;
GO
EXEC sp_rename 'dbo.speech_sig_new', 'speech_sig';
GO

/*  Centroids get the same treatment so the two agree.  */
DROP TABLE IF EXISTS dbo.centroid_new;
GO
SELECT cluster_id = r.new_id, c.embedding, c.row_count, r.super_id
INTO dbo.centroid_new
FROM dbo.centroid c
JOIN dbo.cluster_remap r ON r.old_id = c.cluster_id;
GO
DROP TABLE dbo.centroid;
GO
EXEC sp_rename 'dbo.centroid_new', 'centroid';
GO
ALTER TABLE dbo.centroid ADD CONSTRAINT pk_centroid PRIMARY KEY (cluster_id);
GO

/*  THE CHECK THAT MATTERS.

    Expect {nparts} rowgroups of roughly 26,000 rows, each spanning a
    narrow, non-overlapping cluster_id range. If you still see two
    rowgroups of a million rows, the partition scheme did not apply.  */
SELECT rg.partition_number,
       rg.row_group_id,
       rg.total_rows,
       rg.state_desc,
       mb = rg.size_in_bytes / 1024.0 / 1024.0
FROM sys.dm_db_column_store_row_group_physical_stats rg
WHERE rg.object_id = OBJECT_ID('dbo.speech_sig')
ORDER BY rg.partition_number, rg.row_group_id;
GO

SELECT partitions = COUNT(DISTINCT partition_number),
       rowgroups  = COUNT(*),
       total_mb   = SUM(size_in_bytes) / 1024.0 / 1024.0
FROM sys.dm_db_column_store_row_group_physical_stats
WHERE object_id = OBJECT_ID('dbo.speech_sig');
GO
"""


if __name__ == "__main__":
    cent, counts = read_centroids(os.path.join(OUT_DIR, "centroid.dat"))
    assert len(cent) == NLIST, f"expected {NLIST} centroids, got {len(cent)}"

    new_id, super_assign, order = build_remap(cent, counts)
    write_outputs(new_id, super_assign, order)

    print("\nRun rebuild.sql in SSMS against HANSARD.")
    print("NOTE: after this, cluster ids have changed. Any stored "
          "nprobe query must read centroids from the rebuilt table.")
