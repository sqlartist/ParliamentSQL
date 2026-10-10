/*==============================================================
  HANSARD IVF - rebuild at 512 partitions

  BASELINE (64 partitions, measured over 50 random queries)

      nprobe   spread_avg   rows read    % of table
          50          7.2     309,261         18.2
         100         10.3     431,063         25.3
         200         15.2     610,845         35.9
         417         22.3     844,759         49.7

  Reading half the table at the operating point. The cause is
  granularity, not ordering: each partition holds ~26,000 rows, so
  a single stray cluster in a distant region of embedding space
  costs a full 26,000-row read. Average spread is 22 partitions to
  reach 417 clusters that between them hold ~17,000 rows.

  At 512 partitions each holds ~3,300 rows. Spread will rise - the
  same clusters now fall into more, smaller buckets - but
  sublinearly, because splitting a partition that contains one
  relevant cluster yields one smaller relevant partition, not
  eight. If spread goes 22 -> 60, rows read go 845,000 -> 198,000.

  WHAT THIS COSTS

  3,300-row rowgroups are small by columnstore standards. Expect
  worse compression (88 MB may become 110-120 MB) and more
  per-rowgroup overhead in batch mode. Bytes read should still
  fall by 3-4x, but wall clock will improve by less than that
  ratio suggests. Measure both.

  No renumbering is needed - cluster ids are already ordered by
  super-cluster. This is a new partition function over the same
  ids plus a rebuild.
==============================================================*/

USE HANSARD;
GO
SET NOCOUNT ON;
GO

/*--------------------------------------------------------------
  1. Boundaries

  Equal-count rather than equal-width. Clusters hold between 1 and
  233 speeches, so slicing the id range evenly would give wildly
  uneven partitions. Instead cut on cumulative row count, which
  keeps every partition near 3,300 rows.
--------------------------------------------------------------*/
DECLARE @nparts INT = 512;

DROP TABLE IF EXISTS #bounds;

WITH running AS
(
    SELECT cluster_id,
           row_count,
           cume = SUM(row_count) OVER (ORDER BY cluster_id
                                       ROWS UNBOUNDED PRECEDING)
    FROM dbo.centroid
),
total AS (SELECT t = SUM(row_count) FROM dbo.centroid),
bucketed AS
(
    SELECT r.cluster_id,
           bucket = CASE
                      WHEN (r.cume * @nparts) / t.t >= @nparts
                      THEN @nparts - 1
                      ELSE (r.cume * @nparts) / t.t
                    END
    FROM running r CROSS JOIN total t
)
SELECT bucket, boundary = MAX(cluster_id)
INTO #bounds
FROM bucketed
GROUP BY bucket;

/*  Sanity: how even did that come out?  */
SELECT buckets = COUNT(*) FROM #bounds;
GO

/*--------------------------------------------------------------
  2. Partition function

  RANGE LEFT needs the boundary list as a literal, and there is no
  way to pass 511 values as a variable. Build the statement and
  execute it.
--------------------------------------------------------------*/
DECLARE @sql NVARCHAR(MAX);

SELECT @sql = N'CREATE PARTITION FUNCTION pf_cluster512 (INT) '
            + N'AS RANGE LEFT FOR VALUES ('
            + STRING_AGG(CAST(boundary AS NVARCHAR(20)), N',')
                  WITHIN GROUP (ORDER BY boundary)
            + N');'
FROM #bounds
WHERE bucket < (SELECT MAX(bucket) FROM #bounds);  -- last needs no boundary

IF EXISTS (SELECT 1 FROM sys.partition_schemes WHERE name = 'ps_cluster512')
    DROP PARTITION SCHEME ps_cluster512;
IF EXISTS (SELECT 1 FROM sys.partition_functions WHERE name = 'pf_cluster512')
    DROP PARTITION FUNCTION pf_cluster512;

EXEC sys.sp_executesql @sql;
GO

CREATE PARTITION SCHEME ps_cluster512
    AS PARTITION pf_cluster512 ALL TO ([PRIMARY]);
GO

/*--------------------------------------------------------------
  3. Rebuild

  Table created ON the scheme first - a heap built elsewhere cannot
  take a partitioned columnstore index afterwards, which is the
  error the 64-partition attempt hit.
--------------------------------------------------------------*/
DROP TABLE IF EXISTS dbo.speech_sig512;
GO

CREATE TABLE dbo.speech_sig512
(
    speech_id   INT NOT NULL,
    cluster_id  INT NOT NULL,
    speech_date DATE NOT NULL,
    party_id    SMALLINT NOT NULL,
    sig0 BIGINT NOT NULL, sig1 BIGINT NOT NULL, sig2 BIGINT NOT NULL,
    sig3 BIGINT NOT NULL, sig4 BIGINT NOT NULL, sig5 BIGINT NOT NULL
) ON ps_cluster512 (cluster_id);
GO

INSERT dbo.speech_sig512 WITH (TABLOCK)
    (speech_id, cluster_id, speech_date, party_id,
     sig0, sig1, sig2, sig3, sig4, sig5)
SELECT speech_id, cluster_id, speech_date, party_id,
       sig0, sig1, sig2, sig3, sig4, sig5
FROM dbo.speech_sig;
GO

CREATE CLUSTERED COLUMNSTORE INDEX ccsi_speech_sig512
    ON dbo.speech_sig512
    ORDER (cluster_id)
    ON ps_cluster512 (cluster_id);
GO

/*  Keep the 64-partition table. Having both side by side is the
    comparison, and dropping it loses the baseline.               */

/*--------------------------------------------------------------
  4. What it cost
--------------------------------------------------------------*/
SELECT tbl = 'speech_sig (64)',
       partitions = COUNT(DISTINCT partition_number),
       rowgroups  = COUNT(*),
       rows_total = SUM(total_rows),
       mb         = SUM(size_in_bytes) / 1024.0 / 1024.0
FROM sys.dm_db_column_store_row_group_physical_stats
WHERE object_id = OBJECT_ID('dbo.speech_sig')
UNION ALL
SELECT 'speech_sig512 (512)',
       COUNT(DISTINCT partition_number), COUNT(*), SUM(total_rows),
       SUM(size_in_bytes) / 1024.0 / 1024.0
FROM sys.dm_db_column_store_row_group_physical_stats
WHERE object_id = OBJECT_ID('dbo.speech_sig512');
GO

/*  Rowgroup size distribution. Anything under ~1,000 rows is
    pathologically small and suggests the equal-count bucketing
    did not work.                                                */
SELECT rows_bucket = CASE
          WHEN total_rows <   1000 THEN 'under 1k'
          WHEN total_rows <   2500 THEN '1k-2.5k'
          WHEN total_rows <   5000 THEN '2.5k-5k'
          WHEN total_rows <  10000 THEN '5k-10k'
          ELSE 'over 10k' END,
       rowgroups = COUNT(*)
FROM sys.dm_db_column_store_row_group_physical_stats
WHERE object_id = OBJECT_ID('dbo.speech_sig512')
GROUP BY CASE
          WHEN total_rows <   1000 THEN 'under 1k'
          WHEN total_rows <   2500 THEN '1k-2.5k'
          WHEN total_rows <   5000 THEN '2.5k-5k'
          WHEN total_rows <  10000 THEN '5k-10k'
          ELSE 'over 10k' END;
GO

/*==============================================================
  5. Re-measure spread

  Same 50-query method as before, against the new scheme. The
  comparison that matters is pct_of_tbl at nprobe 417: 49.7% on
  64 partitions.
==============================================================*/
DECLARE @samples INT = 50;

DROP TABLE IF EXISTS #q;
CREATE TABLE #q (n INT IDENTITY(1,1) PRIMARY KEY, speech_id INT NOT NULL);

INSERT #q (speech_id)
SELECT TOP (@samples) speech_id
FROM dbo.speech
WHERE LEN(body) > 1500
ORDER BY NEWID();

DROP TABLE IF EXISTS #result;
CREATE TABLE #result (
    speech_id INT NOT NULL, nprobe INT NOT NULL,
    spread INT NOT NULL, rows_hit INT NOT NULL);

DECLARE @i INT = 1, @n INT = (SELECT COUNT(*) FROM #q);
DECLARE @sid INT, @q VECTOR(384);

WHILE @i <= @n
BEGIN
    SELECT @sid = speech_id FROM #q WHERE n = @i;
    SELECT @q = embedding FROM dbo.speech_vec WHERE speech_id = @sid;

    DROP TABLE IF EXISTS #probe;
    SELECT TOP 417
           cluster_id,
           rnk  = ROW_NUMBER() OVER (
                    ORDER BY VECTOR_DISTANCE('cosine', @q, embedding)),
           part = $PARTITION.pf_cluster512(cluster_id)
    INTO #probe
    FROM dbo.centroid
    ORDER BY VECTOR_DISTANCE('cosine', @q, embedding);

    INSERT #result (speech_id, nprobe, spread, rows_hit)
    SELECT @sid, d.nprobe,
           COUNT(DISTINCT p.part),
           ISNULL((SELECT SUM(c.row_count)
                   FROM dbo.centroid c
                   WHERE $PARTITION.pf_cluster512(c.cluster_id) IN (
                        SELECT p2.part FROM #probe p2
                        WHERE p2.rnk <= d.nprobe)), 0)
    FROM (VALUES (50),(100),(200),(417)) AS d(nprobe)
    JOIN #probe p ON p.rnk <= d.nprobe
    GROUP BY d.nprobe;

    SET @i += 1;
END

DECLARE @total INT = (SELECT COUNT(*) FROM dbo.speech_sig512);

SELECT nprobe,
       spread_min = MIN(spread),
       spread_avg = AVG(spread * 1.0),
       spread_max = MAX(spread),
       rows_avg   = AVG(rows_hit * 1.0),
       pct_of_tbl = AVG(rows_hit * 100.0) / @total
FROM #result
GROUP BY nprobe
ORDER BY nprobe;
GO

/*==============================================================
  6. The real IO comparison

  Spread is a model. This is the measurement. Run both and compare
  lob logical reads - that is bytes off disk, which is the claim.
==============================================================*/
SET STATISTICS IO ON;
GO

DECLARE @q VECTOR(384) = (SELECT embedding FROM dbo.speech_vec
                          WHERE speech_id = 12345);

DROP TABLE IF EXISTS #p;
SELECT TOP 417 cluster_id INTO #p
FROM dbo.centroid
ORDER BY VECTOR_DISTANCE('cosine', @q, embedding);

PRINT '--- 64 partitions ---';
SELECT COUNT(*), MAX(s.sig0)
FROM dbo.speech_sig s
WHERE s.cluster_id IN (SELECT cluster_id FROM #p);

PRINT '--- 512 partitions ---';
SELECT COUNT(*), MAX(s.sig0)
FROM dbo.speech_sig512 s
WHERE s.cluster_id IN (SELECT cluster_id FROM #p);

PRINT '--- full scan, for reference ---';
SELECT COUNT(*), MAX(s.sig0) FROM dbo.speech_sig512 s;
GO
SET STATISTICS IO OFF;
GO
