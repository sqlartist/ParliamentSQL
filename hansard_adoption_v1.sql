/*==============================================================
  HANSARD - ARGUMENT ADOPTION

  Does an argument made by the opposition turn up later in the
  government's mouth?

  TWO ANALYSES, AND THEY NEED DIFFERENT TOOLS

  Part A - WITHIN A BILL. An opposition member speaks at second
  reading; a minister says substantially the same thing at report
  stage six weeks later. A bill's passage generates tens to a few
  hundred speeches, so this is small enough to compute exactly.
  No index needed - it is a self-join over a few hundred rows.
  This is the stronger evidence, because the two speeches are
  provably about the same legislation.

  Part B - ACROSS THE CORPUS. Has this argument appeared anywhere
  in forty years of Parliament, from the other side, later? That
  is 1.7M candidates per query and it is exactly what the IVF
  index is for.

  I did not see this split until I started writing the queries.
  The index I spent a week building is not needed for the
  strongest version of the analysis. It is needed for the
  broadest one.

  WHAT THIS CANNOT DO

  The corpus holds speeches, not tabled amendments. Real
  amendment-text adoption needs Public Bill Committee papers,
  which are a separate ingest. This finds people making the same
  ARGUMENT, which is a proxy and should be described as one.

  Output is CANDIDATE PAIRS FOR A HUMAN TO READ. Similarity is
  not influence - both sides may be reacting to the same select
  committee report or the same front page. Treat the ranking as
  a reading list, not a result.
==============================================================*/

USE HANSARD;
GO
SET NOCOUNT ON;
GO

/*--------------------------------------------------------------
  1. Who was in government

  Simplified to the governing party; the 2010-15 coalition is
  treated as Conservative-led, which is rough but adequate for a
  first pass.
--------------------------------------------------------------*/
DROP TABLE IF EXISTS dbo.gov_period;
GO
CREATE TABLE dbo.gov_period (
    date_from  DATE NOT NULL,
    date_to    DATE NOT NULL,
    gov_party  VARCHAR(50) NOT NULL);

INSERT dbo.gov_period VALUES
    ('1979-05-04', '1997-05-01', 'Conservative'),
    ('1997-05-02', '2010-05-10', 'Labour'),
    ('2010-05-11', '2020-12-31', 'Conservative');
GO

/*  CHECK THE PARTY STRINGS FIRST. 31 distinct values came out of
    the load and I do not know what they look like. If the data
    says 'Con' rather than 'Conservative', everything below
    returns nothing and looks like a null result.                */
SELECT party, speeches = COUNT(*)
FROM dbo.speech
WHERE party IS NOT NULL
GROUP BY party
ORDER BY COUNT(*) DESC;
GO

/*--------------------------------------------------------------
  2. Bills

  major_heading looks like 'Orders of the Day — Water
  Fluoridation Bill' or 'Broadcasting Bill [Lords]'. Strip the
  prefix and the suffix to get something joinable across stages.
--------------------------------------------------------------*/
DROP TABLE IF EXISTS dbo.bill_speech;
GO

SELECT s.speech_id,
       s.speech_date,
       s.party,
       s.speaker_name,
       s.major_heading,
       bill = LTRIM(RTRIM(
                REPLACE(
                  REPLACE(
                    CASE WHEN CHARINDEX(N'—', s.major_heading) > 0
                         THEN SUBSTRING(s.major_heading,
                                CHARINDEX(N'—', s.major_heading) + 1, 500)
                         ELSE s.major_heading END,
                  '[Lords]', ''),
                '[ Lords ]', ''))),
       gov_party = g.gov_party,
       side = CASE WHEN s.party = g.gov_party THEN 'gov' ELSE 'opp' END
INTO dbo.bill_speech
FROM dbo.speech s
JOIN dbo.gov_period g
     ON s.speech_date BETWEEN g.date_from AND g.date_to
WHERE s.major_heading LIKE '%Bill%'
  AND s.party IS NOT NULL
  AND LEN(s.body) > 800;        -- substantive contributions only

CREATE INDEX ix_bill_speech ON dbo.bill_speech (bill, speech_date)
    INCLUDE (speech_id, side);
GO

/*  How many bills, and how much traffic per bill. Bills with one
    stage are no use - adoption needs a before and an after.     */
SELECT bills_total   = COUNT(DISTINCT bill),
       bills_usable  = COUNT(DISTINCT CASE WHEN days > 1 THEN bill END),
       speeches      = SUM(n)
FROM (SELECT bill, n = COUNT(*), days = COUNT(DISTINCT speech_date)
      FROM dbo.bill_speech GROUP BY bill) x;

SELECT TOP 20 bill,
       speeches = COUNT(*),
       stages   = COUNT(DISTINCT speech_date),
       first_seen = MIN(speech_date),
       last_seen  = MAX(speech_date)
FROM dbo.bill_speech
GROUP BY bill
HAVING COUNT(DISTINCT speech_date) > 1
ORDER BY COUNT(*) DESC;
GO

/*==============================================================
  PART A - WITHIN-BILL ADOPTION

  Exact, no index. For each opposition speech, every later
  government speech on the same bill, scored by cosine distance.

  The 14-day gap matters. Same-day pairs are just two people in
  one debate agreeing, which is not adoption, and they would
  dominate the rankings because debate speeches are trivially
  similar to each other.
==============================================================*/
DECLARE @max_dist  FLOAT = 0.25;   -- lower = stricter
DECLARE @min_gap   INT   = 14;     -- days, so different stages
DECLARE @max_gap   INT   = 400;    -- within a parliament's attention span

DROP TABLE IF EXISTS dbo.adoption_pair;
GO

SELECT o.bill,
       opp_id    = o.speech_id,
       opp_date  = o.speech_date,
       opp_who   = o.speaker_name,
       opp_party = o.party,
       gov_id    = g.speech_id,
       gov_date  = g.speech_date,
       gov_who   = g.speaker_name,
       gov_party = g.party,
       lag_days  = DATEDIFF(day, o.speech_date, g.speech_date),
       distance  = VECTOR_DISTANCE('cosine', ov.embedding, gv.embedding)
INTO dbo.adoption_pair
FROM dbo.bill_speech o
JOIN dbo.bill_speech g
     ON  g.bill = o.bill
     AND g.side = 'gov'
     AND DATEDIFF(day, o.speech_date, g.speech_date)
         BETWEEN 14 AND 400
JOIN dbo.speech_vec ov ON ov.speech_id = o.speech_id
JOIN dbo.speech_vec gv ON gv.speech_id = g.speech_id
WHERE o.side = 'opp'
  AND VECTOR_DISTANCE('cosine', ov.embedding, gv.embedding) < 0.25;
GO

CREATE INDEX ix_adoption ON dbo.adoption_pair (distance);
GO

SELECT pairs = COUNT(*), bills = COUNT(DISTINCT bill)
FROM dbo.adoption_pair;
GO

/*  The reading list. Closest pairs first - these are the ones
    worth opening both speeches and judging by eye.             */
SELECT TOP 40
       p.bill,
       p.lag_days,
       dist = CAST(p.distance AS DECIMAL(5,3)),
       p.opp_date, p.opp_who, p.opp_party,
       opp_text = LEFT(so.body, 400),
       p.gov_date, p.gov_who, p.gov_party,
       gov_text = LEFT(sg.body, 400)
FROM dbo.adoption_pair p
JOIN dbo.speech so ON so.speech_id = p.opp_id
JOIN dbo.speech sg ON sg.speech_id = p.gov_id
ORDER BY p.distance;
GO

/*  Which bills show the most convergence. A bill with many close
    pairs is one where the government moved - or one where
    everybody was reading from the same brief.                  */
SELECT TOP 25
       bill,
       close_pairs = COUNT(*),
       tightest    = CAST(MIN(distance) AS DECIMAL(5,3)),
       median_lag  = AVG(lag_days)
FROM dbo.adoption_pair
GROUP BY bill
HAVING COUNT(*) >= 3
ORDER BY COUNT(*) DESC;
GO

/*  Lag distribution. If adoption is real, expect a bump at the
    typical gap between committee and report stage rather than a
    flat spread.                                                 */
SELECT lag_bucket = CASE
          WHEN lag_days <  30 THEN '14-30 days'
          WHEN lag_days <  60 THEN '30-60 days'
          WHEN lag_days < 120 THEN '60-120 days'
          WHEN lag_days < 240 THEN '120-240 days'
          ELSE '240+ days' END,
       pairs = COUNT(*),
       avg_dist = CAST(AVG(distance) AS DECIMAL(5,3))
FROM dbo.adoption_pair
GROUP BY CASE
          WHEN lag_days <  30 THEN '14-30 days'
          WHEN lag_days <  60 THEN '30-60 days'
          WHEN lag_days < 120 THEN '60-120 days'
          WHEN lag_days < 240 THEN '120-240 days'
          ELSE '240+ days' END
ORDER BY MIN(lag_days);
GO

/*==============================================================
  PART B - CORPUS-WIDE ARGUMENT PRIORITY

  Now the index earns its place. Take one opposition speech and
  search all 1.7M for later government speeches making the same
  argument, anywhere, on any bill.

  This is the filtered nearest-neighbour query: semantic
  similarity AND a date floor AND a party restriction, all in one
  WHERE clause over the signature columnstore.
==============================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_who_said_it_later
    @speech_id INT,
    @nprobe    INT = 417,
    @shortlist INT = 750,
    @topk      INT = 20
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @q VECTOR(384), @when DATE, @party VARCHAR(50), @gov VARCHAR(50);

    SELECT @q = embedding FROM dbo.speech_vec WHERE speech_id = @speech_id;
    SELECT @when = speech_date, @party = party
    FROM dbo.speech WHERE speech_id = @speech_id;

    SELECT @gov = gov_party FROM dbo.gov_period
    WHERE @when BETWEEN date_from AND date_to;

    IF @party = @gov
    BEGIN
        RAISERROR('That speech is from the governing party already.', 16, 1);
        RETURN;
    END

    DECLARE @gov_id SMALLINT =
        (SELECT party_id FROM dbo.party WHERE party_name = @gov);

    DECLARE @qs0 BIGINT, @qs1 BIGINT, @qs2 BIGINT,
            @qs3 BIGINT, @qs4 BIGINT, @qs5 BIGINT;
    SELECT @qs0 = sig0, @qs1 = sig1, @qs2 = sig2,
           @qs3 = sig3, @qs4 = sig4, @qs5 = sig5
    FROM dbo.speech_sig WHERE speech_id = @speech_id;

    /*  Stage 1 - nearest signposts  */
    DROP TABLE IF EXISTS #probe;
    SELECT TOP (@nprobe) cluster_id INTO #probe
    FROM dbo.centroid
    ORDER BY VECTOR_DISTANCE('cosine', @q, embedding);

    /*  Stage 2 - Hamming shortlist, filtered to later speeches
        from the governing party. The two predicates ride the
        same columnstore scan as the cluster filter; this is the
        thing a graph index cannot do well.                      */
    DROP TABLE IF EXISTS #cand;
    SELECT TOP (@shortlist) s.speech_id INTO #cand
    FROM dbo.speech_sig s
    WHERE s.cluster_id IN (SELECT cluster_id FROM #probe)
      AND s.speech_date > @when
      AND s.party_id    = @gov_id
    ORDER BY BIT_COUNT(s.sig0 ^ @qs0) + BIT_COUNT(s.sig1 ^ @qs1)
           + BIT_COUNT(s.sig2 ^ @qs2) + BIT_COUNT(s.sig3 ^ @qs3)
           + BIT_COUNT(s.sig4 ^ @qs4) + BIT_COUNT(s.sig5 ^ @qs5);

    /*  Stage 3 - rerank at full precision  */
    SELECT TOP (@topk)
           sp.speech_id,
           sp.speech_date,
           sp.speaker_name,
           sp.major_heading,
           lag_days = DATEDIFF(day, @when, sp.speech_date),
           distance = CAST(VECTOR_DISTANCE('cosine', @q, v.embedding)
                           AS DECIMAL(5,3)),
           extract  = LEFT(sp.body, 400)
    FROM #cand c
    JOIN dbo.speech_vec v ON v.speech_id = c.speech_id
    JOIN dbo.speech    sp ON sp.speech_id = c.speech_id
    ORDER BY distance;
END
GO

/*  Try it against the tightest pair Part A found.  */
DECLARE @best INT = (SELECT TOP 1 opp_id FROM dbo.adoption_pair
                     ORDER BY distance);
EXEC dbo.usp_who_said_it_later @speech_id = @best;
GO

/*==============================================================
  WHAT TO DO WITH THE OUTPUT

  Read twenty pairs before believing any of it. Expect three
  kinds of false positive:

    1. Boilerplate. Procedural language repeats across every bill
       and will score close. If the top of the list is all
       "I beg to move that the Bill be now read a Second time",
       raise the length filter.

    2. Shared source. Both sides quoting the same select
       committee report, the same statistics, the same lobbying
       brief. Converging on a source is not converging on each
       other.

    3. Direct quotation. A minister reading an opposition
       amendment aloud in order to reject it. Semantically
       identical, politically the opposite. Worth a filter on
       whether the government speech contains rejection language.

  The real finding, if there is one, is the lag distribution. If
  adoption happens, it should cluster around the gap between
  committee and report stage rather than being uniform. That is
  a claim the data can support or refuse, which is more than can
  be said for most of this.
==============================================================*/
