/*==============================================================
  HANSARD IVF - end to end benchmark

  Bytes read is a proxy. This measures the thing a reader cares
  about: how long does a query take, and is the answer right.

  Three arms, same 20 query speeches:

    A  brute force    VECTOR_DISTANCE over all 1.7M vectors
    B  three-stage    centroids -> Hamming shortlist -> rerank
    C  DiskANN        SQL Server's own vector index, if built

  Run cold and warm. Cold is the IO argument and wants
  DROPCLEANBUFFERS between runs; warm is what a user actually
  experiences once the signature table is resident. Quote both
  and say which is which - a 681x bytes figure means nothing if
  everything is in memory anyway.

  Parameters from tuning: nprobe 417, shortlist 750, expect
  recall@10 around 0.920.
==============================================================*/

USE HANSARD;
GO
SET NOCOUNT ON;
GO

/*  Repeatable timings matter more than the last few percent, and
    the 285K's P-core/E-core mix makes batch-mode parallelism
    erratic. Pin it.                                              */
DECLARE @maxdop INT = 8;

/*--------------------------------------------------------------
  Query set
--------------------------------------------------------------*/
DROP TABLE IF EXISTS #queries;
CREATE TABLE #queries (
    n INT IDENTITY(1,1) PRIMARY KEY,
    speech_id INT NOT NULL);

INSERT #queries (speech_id)
SELECT TOP 20 speech_id
FROM dbo.speech
WHERE LEN(body) > 1500
ORDER BY NEWID();

DROP TABLE IF EXISTS #timing;
CREATE TABLE #timing (
    arm       VARCHAR(20) NOT NULL,
    cache     VARCHAR(10) NOT NULL,
    speech_id INT NOT NULL,
    ms        INT NOT NULL);

DROP TABLE IF EXISTS #truth;
CREATE TABLE #truth (
    speech_id INT NOT NULL, rank_no INT NOT NULL, hit_id INT NOT NULL);

DROP TABLE IF EXISTS #got;
CREATE TABLE #got (
    arm VARCHAR(20) NOT NULL, speech_id INT NOT NULL,
    rank_no INT NOT NULL, hit_id INT NOT NULL);
GO

/*==============================================================
  ARM A - brute force, and ground truth

  Scans all 1.7M vectors. Also records the true top 10, which
  every other arm is scored against.
==============================================================*/
DECLARE @i INT = 1, @n INT = (SELECT COUNT(*) FROM #queries);
DECLARE @sid INT, @q VECTOR(384), @t DATETIME2(3), @maxdop INT = 8;

WHILE @i <= @n
BEGIN
    SELECT @sid = speech_id FROM #queries WHERE n = @i;
    SELECT @q = embedding FROM dbo.speech_vec WHERE speech_id = @sid;

    SET @t = SYSDATETIME();

    INSERT #truth (speech_id, rank_no, hit_id)
    SELECT @sid,
           ROW_NUMBER() OVER (ORDER BY VECTOR_DISTANCE('cosine', @q, v.embedding)),
           v.speech_id
    FROM (SELECT TOP 10 speech_id, embedding
          FROM dbo.speech_vec
          WHERE speech_id <> @sid
          ORDER BY VECTOR_DISTANCE('cosine', @q, embedding)) v
    OPTION (MAXDOP 8);

    INSERT #timing VALUES
        ('brute', 'warm', @sid, DATEDIFF(ms, @t, SYSDATETIME()));

    SET @i += 1;
END
GO

/*==============================================================
  ARM B - the three-stage path

  1. 417 nearest centroids       (scan 41,730 rows)
  2. Hamming shortlist of 750    (scan the probed partitions)
  3. rerank at full precision    (750 seeks)

  The query signature is derived in SQL here rather than passed
  in, so the benchmark is self-contained. In the real path the
  client computes it alongside the embedding, which removes the
  centroid comparison from the measured work.
==============================================================*/
DECLARE @i INT = 1, @n INT = (SELECT COUNT(*) FROM #queries);
DECLARE @sid INT, @q VECTOR(384), @t DATETIME2(3);
DECLARE @qs0 BIGINT, @qs1 BIGINT, @qs2 BIGINT,
        @qs3 BIGINT, @qs4 BIGINT, @qs5 BIGINT;

WHILE @i <= @n
BEGIN
    SELECT @sid = speech_id FROM #queries WHERE n = @i;
    SELECT @q = embedding FROM dbo.speech_vec WHERE speech_id = @sid;

    /*  The query's own signature. Taken from the stored one,
        which is exactly what the client would compute against
        the same centre vector.                                  */
    SELECT @qs0 = sig0, @qs1 = sig1, @qs2 = sig2,
           @qs3 = sig3, @qs4 = sig4, @qs5 = sig5
    FROM dbo.speech_sig WHERE speech_id = @sid;

    SET @t = SYSDATETIME();

    DROP TABLE IF EXISTS #probe;
    SELECT TOP 417 cluster_id
    INTO #probe
    FROM dbo.centroid
    ORDER BY VECTOR_DISTANCE('cosine', @q, embedding);

    DROP TABLE IF EXISTS #cand;
    SELECT TOP 750 s.speech_id
    INTO #cand
    FROM dbo.speech_sig s
    WHERE s.cluster_id IN (SELECT cluster_id FROM #probe)
      AND s.speech_id <> @sid
    ORDER BY BIT_COUNT(s.sig0 ^ @qs0) + BIT_COUNT(s.sig1 ^ @qs1)
           + BIT_COUNT(s.sig2 ^ @qs2) + BIT_COUNT(s.sig3 ^ @qs3)
           + BIT_COUNT(s.sig4 ^ @qs4) + BIT_COUNT(s.sig5 ^ @qs5);

    INSERT #got (arm, speech_id, rank_no, hit_id)
    SELECT 'ivf', @sid,
           ROW_NUMBER() OVER (ORDER BY VECTOR_DISTANCE('cosine', @q, v.embedding)),
           c.speech_id
    FROM (SELECT TOP 10 c2.speech_id
          FROM #cand c2
          JOIN dbo.speech_vec v2 ON v2.speech_id = c2.speech_id
          ORDER BY VECTOR_DISTANCE('cosine', @q, v2.embedding)) c
    JOIN dbo.speech_vec v ON v.speech_id = c.speech_id;

    INSERT #timing VALUES
        ('ivf', 'warm', @sid, DATEDIFF(ms, @t, SYSDATETIME()));

    SET @i += 1;
END
GO

/*==============================================================
  RESULTS
==============================================================*/
SELECT arm,
       queries = COUNT(*),
       ms_min  = MIN(ms),
       ms_avg  = AVG(ms * 1.0),
       ms_max  = MAX(ms)
FROM #timing
WHERE cache = 'warm'
GROUP BY arm
ORDER BY arm;

/*  Recall: of the 10 true nearest, how many did the IVF path
    find? Tuning predicted 0.920.                                */
SELECT arm = g.arm,
       recall_at_10 = COUNT(*) * 1.0 /
           (SELECT COUNT(DISTINCT speech_id) FROM #truth) / 10
FROM #got g
JOIN #truth t ON t.speech_id = g.speech_id AND t.hit_id = g.hit_id
GROUP BY g.arm;

/*  Per-query recall. An average of 0.92 could be twenty queries
    at 0.92, or eighteen perfect and two disastrous. Worth
    knowing which.                                               */
SELECT g.speech_id,
       found = COUNT(*)
FROM #got g
JOIN #truth t ON t.speech_id = g.speech_id AND t.hit_id = g.hit_id
WHERE g.arm = 'ivf'
GROUP BY g.speech_id
ORDER BY found;

/*  Speedup, stated plainly.  */
SELECT speedup = (SELECT AVG(ms * 1.0) FROM #timing
                  WHERE arm = 'brute' AND cache = 'warm')
              / NULLIF((SELECT AVG(ms * 1.0) FROM #timing
                        WHERE arm = 'ivf' AND cache = 'warm'), 0);
GO

/*==============================================================
  COLD CACHE

  Warm numbers understate the design, because the whole point is
  reading less off disk and a warm cache reads nothing off disk.
  Run this on a machine you can afford to disrupt - it flushes
  the entire buffer pool.

  Do one query per arm, alternating, rather than all of one then
  all of the other: the first arm would warm the second's data.
==============================================================*/
/*
CHECKPOINT;
DBCC DROPCLEANBUFFERS;
GO
-- then a single-query version of arm A, timed
CHECKPOINT;
DBCC DROPCLEANBUFFERS;
GO
-- then a single-query version of arm B, timed
*/

/*==============================================================
  WHAT TO EXPECT

  Brute force scans 1.3 GB of vectors. The IVF path scans ~30 MB
  of signatures and seeks 750 rows. On bytes alone that is a
  large ratio, but warm it will look much smaller, because:

    - 1.3 GB fits in memory on a 96 GB machine, so brute force
      never touches disk after the first run;
    - VECTOR_DISTANCE over 1.7M rows is SIMD work the CPU is
      good at;
    - the IVF path pays fixed costs - scanning 41,730 centroids,
      two temp tables, 750 clustered index seeks - that do not
      shrink with corpus size.

  If the warm speedup is only 3-5x, that is the honest answer and
  the write-up should say so. The bytes argument is real; the
  wall-clock argument at this corpus size may not be. At 50M rows
  it would be a different story, and saying so is more useful
  than pretending 1.7M already proves it.
==============================================================*/
