/*==============================================================
  HANSARD IVF - SQL SERVER 2025 SIDE
  Schema, load plan and query path.

  Parameters from the tuning run against all 1,700,647 speeches:

      nlist      10,432 clusters
      nprobe        104 clusters probed per query
      shortlist     750 rows handed to the reranker
      recall@10   0.920
      reads       1.9 MB/query vs 1,306 MB brute force

  WHY THREE TABLES AND NOT ONE
  ----------------------------
  SQL Server 2025 will not allow a columnstore index on a vector
  column, and will not allow a columnstore index on a table that
  already carries a vector index. They are mutually exclusive. So:

    speech_sig  the 48-byte signatures, in an ordered columnstore.
                This is the thing that gets scanned. ~102 MB.

    speech_vec  the real 384-dim vectors, plain rowstore, looked up
                by id only for the 750 rows that survive. ~1.3 GB,
                but you never scan it.

    centroid    the 10,432 signposts. Tiny. Scanned in full every
                query, which is fine at that size.

  The restriction turns out to be a feature. Scanning 48-byte
  signatures instead of 1,536-byte vectors is where most of the
  681x saving comes from.
==============================================================*/

/*--------------------------------------------------------------
  1. The speeches themselves

  Metadata you want to filter on lives here AND is duplicated into
  speech_sig. That denormalisation is deliberate: filters have to
  be answerable during the columnstore scan, or you lose rowgroup
  elimination and the whole design with it.
--------------------------------------------------------------*/
DROP TABLE IF EXISTS dbo.speech;
GO
CREATE TABLE dbo.speech
(
    speech_id     INT           NOT NULL,
    speech_date   DATE          NOT NULL,
    party         NVARCHAR(100) NULL,
    speaker_name  NVARCHAR(200) NULL,
    person_id     NVARCHAR(50)  NULL,
    major_heading NVARCHAR(500) NULL,
    minor_heading NVARCHAR(500) NULL,
    body          NVARCHAR(MAX) NULL,
    url           NVARCHAR(500) NULL,
    CONSTRAINT pk_speech PRIMARY KEY CLUSTERED (speech_id)
);
GO

/*--------------------------------------------------------------
  2. The signature table - the one that does the work

  Six BIGINTs hold 384 bits: one bit per embedding dimension,
  recording whether that dimension was above or below average.
  A crude summary of the vector, but 32x smaller and enough to
  shortlist with.

  The ORDER (cluster_id) clause is the whole point. It physically
  groups rows by cluster, so each rowgroup's min/max metadata lets
  the engine skip rowgroups whose clusters you did not probe.
  Without ORDER you get a columnstore that compresses nicely and
  eliminates nothing.
--------------------------------------------------------------*/
DROP TABLE IF EXISTS dbo.speech_sig;
GO
CREATE TABLE dbo.speech_sig
(
    speech_id   INT    NOT NULL,
    cluster_id  INT    NOT NULL,
    speech_date DATE   NOT NULL,   -- denormalised for filtering
    party_id    SMALLINT NULL,     -- denormalised for filtering
    sig0 BIGINT NOT NULL, sig1 BIGINT NOT NULL, sig2 BIGINT NOT NULL,
    sig3 BIGINT NOT NULL, sig4 BIGINT NOT NULL, sig5 BIGINT NOT NULL
);
GO

/*  Load as a heap first, then build the ordered index. Building
    the index on an empty table and inserting afterwards does NOT
    guarantee ordering - the sort happens at index build time.    */

/*--------------------------------------------------------------
  3. The vectors - fetched, never scanned
--------------------------------------------------------------*/
DROP TABLE IF EXISTS dbo.speech_vec;
GO
CREATE TABLE dbo.speech_vec
(
    speech_id INT NOT NULL,
    embedding VECTOR(384) NOT NULL,
    CONSTRAINT pk_speech_vec PRIMARY KEY CLUSTERED (speech_id)
);
GO

/*--------------------------------------------------------------
  4. The centroids - the signposts
--------------------------------------------------------------*/
DROP TABLE IF EXISTS dbo.centroid;
GO
CREATE TABLE dbo.centroid
(
    cluster_id INT NOT NULL,
    embedding  VECTOR(384) NOT NULL,
    row_count  INT NULL,            -- handy for sanity checks
    CONSTRAINT pk_centroid PRIMARY KEY CLUSTERED (cluster_id)
);
GO

/*==============================================================
  5. LOADING

  Order matters. Build the ordered columnstore AFTER the data is
  in, or the rows will not be physically sorted.

  From Python, write four CSVs - speech, speech_sig, speech_vec,
  centroid - then bcp them in. The vector column ingests as a JSON
  array string, e.g. '[0.013,-0.221,...]', which is bulky; expect
  the vector load to be the slow part. pyodbc with fast_executemany
  is the alternative if bcp formatting gets painful.

  Packing the signatures in numpy:

      centre = vecs.mean(axis=0)
      bits   = (vecs > centre).astype(np.uint8)        # n x 384
      packed = np.packbits(bits, axis=1)               # n x 48 bytes
      sigs   = packed.view('>i8')                      # n x 6 BIGINT

  Use the SAME centre vector for queries at search time, or the
  signatures will not be comparable. Store it somewhere.
==============================================================*/

-- After bcp has populated dbo.speech_sig as a heap:
CREATE CLUSTERED COLUMNSTORE INDEX ccsi_speech_sig
    ON dbo.speech_sig
    ORDER (cluster_id);
GO

/*  Check the ordering actually took. Rowgroups should show tight,
    mostly non-overlapping cluster_id ranges. If min/max spans the
    whole range in every rowgroup, the ORDER did not apply and
    nothing will be eliminated.                                   */
SELECT rg.row_group_id,
       rg.total_rows,
       rg.size_in_bytes / 1024 / 1024 AS mb,
       min_cluster = seg.min_data_id,
       max_cluster = seg.max_data_id
FROM sys.dm_db_column_store_row_group_physical_stats rg
JOIN sys.column_store_segments seg
     ON  seg.hobt_id  = rg.object_id        -- see note below
     AND seg.segment_id = rg.row_group_id
JOIN sys.columns c
     ON  c.object_id = rg.object_id
     AND c.column_id = seg.column_id
WHERE rg.object_id = OBJECT_ID('dbo.speech_sig')
  AND c.name = 'cluster_id'
ORDER BY rg.row_group_id;
GO
/*  (The hobt_id join above is approximate - if it returns nothing,
    join sys.column_store_segments through sys.partitions on
    hobt_id instead. Easier quick check: just look at total_rows
    and state_desc per rowgroup and confirm you have ~1,700
    COMPRESSED rowgroups of about a million rows each... actually
    of 1,048,576 max, so roughly 2.)                              */

/*==============================================================
  6. THE QUERY PATH

  Three stages, matching the three tables:

    1. Which 104 clusters are nearest?     -> centroid
    2. Which 750 rows look closest?        -> speech_sig  (scan)
    3. Which 10 actually are?              -> speech_vec  (seek)

  The query embedding and its six signature BIGINTs are computed
  client-side and passed in. SQL Server never runs the model.
==============================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_similar_speeches
    @q           VECTOR(384),
    @qs0 BIGINT, @qs1 BIGINT, @qs2 BIGINT,
    @qs3 BIGINT, @qs4 BIGINT, @qs5 BIGINT,
    @nprobe      INT  = 104,
    @shortlist   INT  = 750,
    @topk        INT  = 10,
    @date_from   DATE = NULL,      -- the filters that make this
    @date_to     DATE = NULL,      -- worth doing at all
    @party_id    SMALLINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    /*  Stage 1: nearest signposts. 10,432 rows, scanned in full.
        Materialised into a temp table rather than left as a CTE so
        the optimiser treats it as a small known set in stage 2.   */
    DROP TABLE IF EXISTS #probe;
    SELECT TOP (@nprobe) cluster_id
    INTO #probe
    FROM dbo.centroid
    ORDER BY VECTOR_DISTANCE('cosine', @q, embedding);

    /*  Stage 2: Hamming shortlist over the columnstore.

        XOR the query signature against each row's, count the bits
        that differ - that is Hamming distance. Fewer differing
        bits means more similar. Six BIT_COUNTs per row, in batch
        mode, over ~22,000 surviving rows.

        The date and party predicates ride along for free: they are
        columns in the same rowgroups, so they narrow the scan
        rather than filtering afterwards.                          */
    DROP TABLE IF EXISTS #cand;
    SELECT TOP (@shortlist) s.speech_id
    INTO #cand
    FROM dbo.speech_sig s
    WHERE s.cluster_id IN (SELECT cluster_id FROM #probe)
      AND (@date_from IS NULL OR s.speech_date >= @date_from)
      AND (@date_to   IS NULL OR s.speech_date <= @date_to)
      AND (@party_id  IS NULL OR s.party_id    = @party_id)
    ORDER BY BIT_COUNT(s.sig0 ^ @qs0) + BIT_COUNT(s.sig1 ^ @qs1)
           + BIT_COUNT(s.sig2 ^ @qs2) + BIT_COUNT(s.sig3 ^ @qs3)
           + BIT_COUNT(s.sig4 ^ @qs4) + BIT_COUNT(s.sig5 ^ @qs5);

    /*  Stage 3: rerank the survivors at full precision. 750 clustered
        index seeks, which is the single most expensive part of the
        query by bytes read - 750 x 1,536 bytes.                   */
    SELECT TOP (@topk)
           sp.speech_id,
           sp.speech_date,
           sp.speaker_name,
           sp.party,
           sp.major_heading,
           distance = VECTOR_DISTANCE('cosine', @q, v.embedding),
           extract  = LEFT(sp.body, 300)
    FROM #cand c
    JOIN dbo.speech_vec v ON v.speech_id = c.speech_id
    JOIN dbo.speech    sp ON sp.speech_id = c.speech_id
    ORDER BY distance;
END
GO

/*==============================================================
  7. THE THING TO VERIFY

  Everything above assumes rowgroup elimination actually happens.
  It is NOT guaranteed - segment elimination is reliable for simple
  predicates on the ordering column, but an IN against a subquery
  may not qualify, in which case SQL Server scans all ~1,700
  rowgroups and you get compression but no skipping.

  Run with:

      SET STATISTICS IO ON;

  and look at the "segment reads" and "segment skipped" counts for
  speech_sig. You want skipped to be the large number. If skipped
  is zero:

    a) try a literal IN list built as dynamic SQL instead of the
       temp table join, which gives the optimiser constants to
       work with;
    b) check the rowgroup ranges from section 5 - if ORDER did not
       take, nothing will ever be skipped;
    c) compare elapsed time against a deliberately unordered copy
       of the same table. If they match, elimination is not
       happening whatever the DMVs say.

  This is the one experimental result the whole demo rests on. 
  its worth getting right.
==============================================================*/
