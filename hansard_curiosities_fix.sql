/*==============================================================
  HANSARD CURIOSITIES - fixes

  TWO BUGS

  1. Square brackets are LIKE wildcards. '%[Interruption.]%'
     asks for any single character from the set {I,n,t,e,r,u,p,
     o,.} - which is every speech ever written. Hence 1,700,647
     matches and a House where every MP is funny 100% of the
     time. CHARINDEX does no pattern matching, so it is the
     right tool for a literal string.

  2. The crossover query nested MIN() inside a CASE inside
     MIN(). Restructured to compute each speaker's own party
     separately and pivot afterwards.

  Sections 3 and 5 of the original were sound and do not need
  rerunning.
==============================================================*/

USE HANSARD;
GO
SET NOCOUNT ON;
GO

/*==============================================================
  1. What is ACTUALLY in the text

  If laughter and interruption come back in the low thousands,
  the dataset kept the markers and section 2 is worth running.
  If they come back near zero, the parse stripped them and
  chamber reaction is simply not recoverable from this corpus.
==============================================================*/
SELECT marker = '[Interruption.]', speeches = COUNT(*)
FROM dbo.speech WHERE CHARINDEX('[Interruption.]', body) > 0
UNION ALL SELECT '[Laughter.]', COUNT(*)
FROM dbo.speech WHERE CHARINDEX('[Laughter.]', body) > 0
UNION ALL SELECT 'Interruption (any)', COUNT(*)
FROM dbo.speech WHERE CHARINDEX('Interruption', body) > 0
UNION ALL SELECT 'Laughter (any)', COUNT(*)
FROM dbo.speech WHERE CHARINDEX('Laughter', body) > 0
UNION ALL SELECT 'Hear, hear', COUNT(*)
FROM dbo.speech WHERE CHARINDEX('Hear, hear', body) > 0
UNION ALL SELECT 'Hon. Members:', COUNT(*)
FROM dbo.speech WHERE CHARINDEX('Hon. Members:', body) > 0
UNION ALL SELECT 'Rubbish', COUNT(*)
FROM dbo.speech WHERE CHARINDEX('Rubbish', body) > 0
UNION ALL SELECT 'Order, order', COUNT(*)
FROM dbo.speech WHERE CHARINDEX('Order, order', body) > 0
UNION ALL SELECT 'give way', COUNT(*)
FROM dbo.speech WHERE CHARINDEX('give way', body) > 0
UNION ALL SELECT 'I give way', COUNT(*)
FROM dbo.speech WHERE CHARINDEX('I give way', body) > 0
ORDER BY speeches DESC;
GO

/*==============================================================
  2. Reaction leaderboards, now that the match works

  'Unknown' is excluded - it is 57,733 speeches of unattributed
  text and would otherwise top every chart.
==============================================================*/
DROP TABLE IF EXISTS #reaction;

SELECT r.speech_id, r.speaker_name, r.party, r.role, r.speech_date,
       words      = LEN(s.body) - LEN(REPLACE(s.body, ' ', '')) + 1,
       laughter   = CASE WHEN CHARINDEX('Laughter', s.body) > 0 THEN 1 ELSE 0 END,
       interrupt  = CASE WHEN CHARINDEX('Interruption', s.body) > 0 THEN 1 ELSE 0 END,
       hearhear   = CASE WHEN CHARINDEX('Hear, hear', s.body) > 0 THEN 1 ELSE 0 END,
       gaveway    = CASE WHEN CHARINDEX('give way', s.body) > 0 THEN 1 ELSE 0 END
INTO #reaction
FROM dbo.speech_role r
JOIN dbo.speech s ON s.speech_id = r.speech_id
WHERE r.role <> 'chair'
  AND r.speaker_name <> 'Unknown'
  AND r.speaker_name IS NOT NULL;

CREATE INDEX ix_reaction ON #reaction (speaker_name);
GO

SELECT total_speeches = COUNT(*),
       with_laughter  = SUM(laughter),
       with_interrupt = SUM(interrupt),
       with_hearhear  = SUM(hearhear)
FROM #reaction;
GO

/*  Funniest MPs.  */
SELECT TOP 25 speaker_name, party = MIN(party),
       speeches = COUNT(*), laughs = SUM(laughter),
       pct_funny = CAST(100.0 * SUM(laughter) / COUNT(*) AS DECIMAL(5,2))
FROM #reaction
GROUP BY speaker_name
HAVING COUNT(*) >= 200 AND SUM(laughter) >= 5
ORDER BY 100.0 * SUM(laughter) / COUNT(*) DESC;
GO

/*  Most shouted at.  */
SELECT TOP 25 speaker_name, party = MIN(party),
       speeches = COUNT(*), interrupted = SUM(interrupt),
       pct = CAST(100.0 * SUM(interrupt) / COUNT(*) AS DECIMAL(5,2))
FROM #reaction
GROUP BY speaker_name
HAVING COUNT(*) >= 200 AND SUM(interrupt) >= 5
ORDER BY 100.0 * SUM(interrupt) / COUNT(*) DESC;
GO

/*  Is the House getting rowdier?  */
SELECT decade = (YEAR(speech_date) / 10) * 10,
       speeches = COUNT(*),
       pct_laughter  = CAST(100.0 * SUM(laughter)  / COUNT(*) AS DECIMAL(6,3)),
       pct_interrupt = CAST(100.0 * SUM(interrupt) / COUNT(*) AS DECIMAL(6,3)),
       pct_hearhear  = CAST(100.0 * SUM(hearhear)  / COUNT(*) AS DECIMAL(6,3)),
       pct_giveway   = CAST(100.0 * SUM(gaveway)   / COUNT(*) AS DECIMAL(6,3))
FROM #reaction
GROUP BY (YEAR(speech_date) / 10) * 10
ORDER BY decade;
GO

/*  By party.  */
SELECT party, speeches = COUNT(*),
       pct_laughter  = CAST(100.0 * SUM(laughter)  / COUNT(*) AS DECIMAL(6,3)),
       pct_interrupt = CAST(100.0 * SUM(interrupt) / COUNT(*) AS DECIMAL(6,3)),
       pct_hearhear  = CAST(100.0 * SUM(hearhear)  / COUNT(*) AS DECIMAL(6,3))
FROM #reaction
GROUP BY party
HAVING COUNT(*) >= 5000
ORDER BY 100.0 * SUM(laughter) / COUNT(*) DESC;
GO

/*  Ministers versus everyone else - does office protect you
    from being laughed at, or invite it?                       */
SELECT role, speeches = COUNT(*),
       pct_laughter  = CAST(100.0 * SUM(laughter)  / COUNT(*) AS DECIMAL(6,3)),
       pct_interrupt = CAST(100.0 * SUM(interrupt) / COUNT(*) AS DECIMAL(6,3))
FROM #reaction GROUP BY role;
GO

/*==============================================================
  3. Crossover, fixed

  Rebuilds #sample and #ref in case the session was reset. Each
  speaker is compared against a reference sample of Conservative
  and Labour speeches; positive crossover means they sound more
  like the other side than their own.
==============================================================*/
DROP TABLE IF EXISTS #sample;

WITH eligible AS
(
    SELECT speaker_name, n = COUNT(*)
    FROM dbo.speech_role
    WHERE role <> 'chair' AND speaker_name IS NOT NULL
      AND speaker_name <> 'Unknown'
    GROUP BY speaker_name
    HAVING COUNT(*) >= 100
),
picked AS
(
    SELECT r.speaker_name, r.speech_id, r.party,
           rn = ROW_NUMBER() OVER (PARTITION BY r.speaker_name
                                   ORDER BY NEWID())
    FROM dbo.speech_role r
    JOIN eligible e ON e.speaker_name = r.speaker_name
    JOIN dbo.speech s ON s.speech_id = r.speech_id
    WHERE r.role <> 'chair' AND LEN(s.body) > 1000
)
SELECT speaker_name, speech_id, party
INTO #sample FROM picked WHERE rn <= 30;

CREATE INDEX ix_sample ON #sample (speaker_name) INCLUDE (speech_id);
GO

DROP TABLE IF EXISTS #ref;

SELECT TOP 400 speech_id, party = CAST('Conservative' AS VARCHAR(20))
INTO #ref
FROM dbo.speech_role
WHERE party = 'Conservative' AND role <> 'chair'
ORDER BY NEWID();

INSERT #ref
SELECT TOP 400 speech_id, 'Labour'
FROM dbo.speech_role
WHERE party = 'Labour' AND role <> 'chair'
ORDER BY NEWID();
GO

/*  own_party is resolved in its own CTE so no aggregate ends up
    nested inside another one - that was the error.            */
WITH spk AS
(
    SELECT speaker_name, own_party = MIN(party)
    FROM #sample GROUP BY speaker_name
),
scored AS
(
    SELECT s.speaker_name,
           ref_party = f.party,
           d = AVG(VECTOR_DISTANCE('cosine', sv.embedding, fv.embedding))
    FROM #sample s
    CROSS JOIN #ref f
    JOIN dbo.speech_vec sv ON sv.speech_id = s.speech_id
    JOIN dbo.speech_vec fv ON fv.speech_id = f.speech_id
    GROUP BY s.speaker_name, f.party
),
pivoted AS
(
    SELECT sc.speaker_name,
           k.own_party,
           to_con = MAX(CASE WHEN sc.ref_party = 'Conservative' THEN sc.d END),
           to_lab = MAX(CASE WHEN sc.ref_party = 'Labour'       THEN sc.d END)
    FROM scored sc
    JOIN spk k ON k.speaker_name = sc.speaker_name
    WHERE k.own_party IN ('Conservative', 'Labour')
    GROUP BY sc.speaker_name, k.own_party
)
SELECT TOP 30
       speaker_name, own_party,
       to_con = CAST(to_con AS DECIMAL(6,4)),
       to_lab = CAST(to_lab AS DECIMAL(6,4)),
       crossover = CAST(CASE WHEN own_party = 'Conservative'
                             THEN to_con - to_lab
                             ELSE to_lab - to_con END AS DECIMAL(6,4))
FROM pivoted
ORDER BY crossover DESC;
GO

/*  And the loyalists - the ones furthest from the other side.  */
WITH spk AS
(
    SELECT speaker_name, own_party = MIN(party)
    FROM #sample GROUP BY speaker_name
),
scored AS
(
    SELECT s.speaker_name, ref_party = f.party,
           d = AVG(VECTOR_DISTANCE('cosine', sv.embedding, fv.embedding))
    FROM #sample s
    CROSS JOIN #ref f
    JOIN dbo.speech_vec sv ON sv.speech_id = s.speech_id
    JOIN dbo.speech_vec fv ON fv.speech_id = f.speech_id
    GROUP BY s.speaker_name, f.party
),
pivoted AS
(
    SELECT sc.speaker_name, k.own_party,
           to_con = MAX(CASE WHEN sc.ref_party = 'Conservative' THEN sc.d END),
           to_lab = MAX(CASE WHEN sc.ref_party = 'Labour'       THEN sc.d END)
    FROM scored sc
    JOIN spk k ON k.speaker_name = sc.speaker_name
    WHERE k.own_party IN ('Conservative', 'Labour')
    GROUP BY sc.speaker_name, k.own_party
)
SELECT TOP 30
       speaker_name, own_party,
       to_con = CAST(to_con AS DECIMAL(6,4)),
       to_lab = CAST(to_lab AS DECIMAL(6,4)),
       crossover = CAST(CASE WHEN own_party = 'Conservative'
                             THEN to_con - to_lab
                             ELSE to_lab - to_con END AS DECIMAL(6,4))
FROM pivoted
ORDER BY crossover ASC;
GO
