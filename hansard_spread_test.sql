/*==============================================================
  HANSARD IVF - partition spread sampling

  One query gave spread 16 at nprobe 417. That is one draw. Before
  rebuilding with more partitions, find out whether 16 is typical,
  and how much it varies.

  The measurement is: for a given query vector, how many of the 64
  partitions do its N nearest clusters fall into? Every partition
  touched costs a whole rowgroup read (~26,000 rows), so spread is
  what actually determines IO - not nprobe, and not row count.

  Runs 50 random query speeches at four probe depths. Takes a couple
  of minutes; the cost is 50 x 4 scans of the 41,730-row centroid
  table, which is small.
==============================================================*/

USE HANSARD;
GO
SET NOCOUNT ON;
GO

DECLARE @samples INT = 50;

DROP TABLE IF EXISTS #q;
CREATE TABLE #q (n INT IDENTITY(1,1) PRIMARY KEY, speech_id INT NOT NULL);

/*  Random speeches, but only ones long enough to have a meaningful
    embedding. A 45-word procedural interjection is a legitimate row
    but a poor query, and it would skew the sample.                 */
INSERT #q (speech_id)
SELECT TOP (@samples) speech_id
FROM dbo.speech
WHERE LEN(body) > 1500
ORDER BY NEWID();

DROP TABLE IF EXISTS #result;
CREATE TABLE #result (
    speech_id INT NOT NULL,
    nprobe    INT NOT NULL,
    spread    INT NOT NULL,
    rows_hit  INT NOT NULL);

DECLARE @i INT = 1, @n INT = (SELECT COUNT(*) FROM #q);
DECLARE @sid INT, @q VECTOR(384);

WHILE @i <= @n
BEGIN
    SELECT @sid = speech_id FROM #q WHERE n = @i;
    SELECT @q = embedding FROM dbo.speech_vec WHERE speech_id = @sid;

    /*  One ranked pass over the centroids, reused for all four
        depths - ordering 41,730 rows once per query rather than
        four times.                                               */
    DROP TABLE IF EXISTS #probe;
    SELECT TOP 417
           cluster_id,
           rnk = ROW_NUMBER() OVER (
                   ORDER BY VECTOR_DISTANCE('cosine', @q, embedding)),
           part = $PARTITION.pf_cluster(cluster_id)
    INTO #probe
    FROM dbo.centroid
    ORDER BY VECTOR_DISTANCE('cosine', @q, embedding);

    INSERT #result (speech_id, nprobe, spread, rows_hit)
    SELECT @sid, d.nprobe,
           COUNT(DISTINCT p.part),
           /*  Rows actually read = every row in every partition
               touched, not just the probed clusters.              */
           ISNULL((SELECT SUM(c.row_count)
                   FROM dbo.centroid c
                   WHERE $PARTITION.pf_cluster(c.cluster_id) IN (
                        SELECT p2.part FROM #probe p2
                        WHERE p2.rnk <= d.nprobe)), 0)
    FROM (VALUES (50),(100),(200),(417)) AS d(nprobe)
    JOIN #probe p ON p.rnk <= d.nprobe
    GROUP BY d.nprobe;

    SET @i += 1;
END

/*--------------------------------------------------------------
  Results
--------------------------------------------------------------*/
DECLARE @total INT = (SELECT COUNT(*) FROM dbo.speech_sig);

SELECT nprobe,
       samples    = COUNT(*),
       spread_min = MIN(spread),
       spread_avg = AVG(spread * 1.0),
       spread_p90 = MAX(spread),          -- replaced below if 2022+
       rows_avg   = AVG(rows_hit * 1.0),
       pct_of_tbl = AVG(rows_hit * 100.0) / @total
FROM #result
GROUP BY nprobe
ORDER BY nprobe;

/*  Distribution at the operating point. If this is tight, one
    sample was enough. If it runs from 8 to 50, the average is
    hiding queries that scan most of the table.                  */
SELECT spread, queries = COUNT(*)
FROM #result
WHERE nprobe = 417
GROUP BY spread
ORDER BY spread;

/*  The worst cases are worth looking at - a query whose neighbours
    are scattered across 40 partitions is usually a speech that is
    semantically unlike anything, and those are interesting in
    their own right.                                              */
SELECT TOP 5 r.spread, s.speech_date, s.speaker_name, s.major_heading,
       extract = LEFT(s.body, 150)
FROM #result r
JOIN dbo.speech s ON s.speech_id = r.speech_id
WHERE r.nprobe = 417
ORDER BY r.spread DESC;

/*--------------------------------------------------------------
  What to conclude

    pct_of_tbl at nprobe 417 is the real IO figure. At 64
    partitions with spread 16 that is ~25%.

    If spread_avg is near 16 and the distribution is tight, the
    rebuild at 512 partitions is worth doing: each partition holds
    ~3,300 rows instead of 26,000, and spread should grow
    sublinearly because isolated strays stay isolated when you
    split the partition around them.

    If spread varies wildly - some queries at 5, others at 45 -
    then average IO is not the right claim and the write-up should
    quote a distribution instead. That is a more honest result and
    a more interesting one.
--------------------------------------------------------------*/
