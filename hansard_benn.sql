/*==============================================================
  TONY BENN

  What does 1.7 million speeches have to say about the man?

  Section 4 is the one that matters. Benn's five questions -
  "What power have you got? Where did you get it from? In whose
  interest do you exercise it? To whom are you accountable? And
  how can we get rid of you?" - are the most famous formulation
  any backbencher produced in this period, and he repeated them
  for thirty years.

  If the phrase pipeline did not find them, that is the single
  cleanest measurement of what the method misses, because this
  is the easiest possible case and I know the answer in advance.
==============================================================*/

USE HANSARD;
GO
SET NOCOUNT ON;
GO

/*==============================================================
  1. Which Benn is which

  569 speeches is far too few for a man who sat from 1979 to
  2001. The name is almost certainly split. His son Hilary sat
  from 1999, so the two overlap for two years and have to be
  kept apart by date.
==============================================================*/
SELECT speaker_name,
       party    = MIN(party),
       speeches = COUNT(*),
       first    = MIN(speech_date),
       last     = MAX(speech_date),
       as_minister = SUM(CASE WHEN role = 'minister' THEN 1 ELSE 0 END)
FROM dbo.speech_role
WHERE CHARINDEX('Benn', speaker_name) > 0
GROUP BY speaker_name
ORDER BY COUNT(*) DESC;
GO

/*  Everything that is him, as one person. Hilary entered in
    1999 and is excluded by name, not by date, because Tony was
    still sitting until 2001.                                   */
DROP TABLE IF EXISTS #benn;

SELECT r.speech_id, r.speech_date, r.speaker_name, r.role,
       words = LEN(s.body) - LEN(REPLACE(s.body, ' ', '')) + 1,
       s.body
INTO #benn
FROM dbo.speech_role r
JOIN dbo.speech s ON s.speech_id = r.speech_id
WHERE CHARINDEX('Benn', r.speaker_name) > 0
  AND CHARINDEX('Hilary', r.speaker_name) = 0
  AND r.speech_date < '2001-06-07'      -- he stood down at that election
  AND r.role <> 'chair';

CREATE INDEX ix_benn ON #benn (speech_id);
GO

SELECT total_speeches = COUNT(*),
       total_words  = SUM(CAST(words AS BIGINT)),
       avg_words    = CAST(AVG(words * 1.0) AS DECIMAL(8,1)),
       longest      = MAX(words),
       hours_approx = CAST(SUM(CAST(words AS BIGINT)) / 130.0 / 60.0 AS DECIMAL(8,1)),
       first_in_corpus = MIN(speech_date),
       last_in_corpus  = MAX(speech_date)
FROM #benn;
GO

/*==============================================================
  2. How the House treated him, against the House average
==============================================================*/
SELECT who = 'Benn',
       speeches = COUNT(*),
       pct_interrupt = CAST(100.0 * SUM(CASE WHEN CHARINDEX('Interruption', body) > 0
                                        THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(6,3)),
       pct_laughter  = CAST(100.0 * SUM(CASE WHEN CHARINDEX('Laughter', body) > 0
                                        THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(6,3)),
       pct_hearhear  = CAST(100.0 * SUM(CASE WHEN CHARINDEX('Hear, hear', body) > 0
                                        THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(6,3)),
       pct_giveway   = CAST(100.0 * SUM(CASE WHEN CHARINDEX('give way', body) > 0
                                        THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(6,3))
FROM #benn
UNION ALL
SELECT 'The House 1979-2001', COUNT(*),
       CAST(100.0 * SUM(CASE WHEN CHARINDEX('Interruption', s.body) > 0
                        THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(6,3)),
       CAST(100.0 * SUM(CASE WHEN CHARINDEX('Laughter', s.body) > 0
                        THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(6,3)),
       CAST(100.0 * SUM(CASE WHEN CHARINDEX('Hear, hear', s.body) > 0
                        THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(6,3)),
       CAST(100.0 * SUM(CASE WHEN CHARINDEX('give way', s.body) > 0
                        THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(6,3))
FROM dbo.speech_role r
JOIN dbo.speech s ON s.speech_id = r.speech_id
WHERE r.role <> 'chair' AND r.speech_date < '2001-06-07';
GO

/*==============================================================
  3. Broken record, or range?

  The reputation is of a man with a small number of themes he
  returned to relentlessly. The self-similarity measure says
  whether that is true. Low distance = says the same thing over
  and over. For reference: the most repetitive MP in the corpus
  scored 0.2006, the most varied 0.3398.
==============================================================*/
DROP TABLE IF EXISTS #bsample;

SELECT TOP 60 speech_id
INTO #bsample
FROM #benn WHERE words > 300
ORDER BY NEWID();
GO

SELECT who = 'Benn',
       pairs = COUNT(*),
       self_distance = CAST(AVG(VECTOR_DISTANCE('cosine',
                            av.embedding, bv.embedding)) AS DECIMAL(6,4))
FROM #bsample a
JOIN #bsample b ON b.speech_id > a.speech_id
JOIN dbo.speech_vec av ON av.speech_id = a.speech_id
JOIN dbo.speech_vec bv ON bv.speech_id = b.speech_id;
GO

/*==============================================================
  4. THE FIVE QUESTIONS

  The test. If this comes back empty, either Hansard never
  recorded him saying them in the Commons, or my tokeniser
  mangled them.
==============================================================*/
SELECT fragment = 'what power have you got',       n = COUNT(*)
FROM dbo.speech WHERE CHARINDEX('what power have you got', LOWER(body)) > 0
UNION ALL SELECT 'where did you get it', COUNT(*)
FROM dbo.speech WHERE CHARINDEX('where did you get it', LOWER(body)) > 0
UNION ALL SELECT 'in whose interest', COUNT(*)
FROM dbo.speech WHERE CHARINDEX('in whose interest', LOWER(body)) > 0
UNION ALL SELECT 'to whom are you accountable', COUNT(*)
FROM dbo.speech WHERE CHARINDEX('to whom are you accountable', LOWER(body)) > 0
UNION ALL SELECT 'how can we get rid of you', COUNT(*)
FROM dbo.speech WHERE CHARINDEX('how can we get rid of you', LOWER(body)) > 0
UNION ALL SELECT 'how do we get rid of you', COUNT(*)
FROM dbo.speech WHERE CHARINDEX('how do we get rid of you', LOWER(body)) > 0
ORDER BY n DESC;
GO

/*  Who actually said them, and when. If anyone other than Benn
    appears here, the five questions crossed the floor - which
    would be the only confirmed case of adoption in this entire
    project, found by asking about one man.                    */
SELECT r.speaker_name, r.party, r.speech_date,
       debate = LEFT(REPLACE(r.major_heading, NCHAR(160), N' '), 60),
       extract = SUBSTRING(s.body,
                   CASE WHEN CHARINDEX('whose interest', LOWER(s.body)) > 150
                        THEN CHARINDEX('whose interest', LOWER(s.body)) - 150
                        ELSE 1 END, 450)
FROM dbo.speech s
JOIN dbo.speech_role r ON r.speech_id = s.speech_id
WHERE CHARINDEX('in whose interest', LOWER(s.body)) > 0
  AND CHARINDEX('accountable', LOWER(s.body)) > 0
ORDER BY r.speech_date;
GO

/*  And did the phrase pipeline catch any of it?               */
SELECT phrase, uses, burstiness, coiner, coiner_party,
       first_year, later_who, later_party
FROM dbo.phrase_attr2
WHERE CHARINDEX('whose interest', phrase) > 0
   OR CHARINDEX('power have you', phrase) > 0
   OR CHARINDEX('are you accountable', phrase) > 0
   OR CHARINDEX('get rid of you', phrase) > 0;
GO

/*==============================================================
  5. His own vocabulary

  Words Benn used far more than the House did. The reputation is
  of a man who talked about process and power rather than
  policy; this is whether the text agrees.
==============================================================*/
DROP TABLE IF EXISTS #bwords;

SELECT w = LOWER(value), n = COUNT(*)
INTO #bwords
FROM #benn CROSS APPLY STRING_SPLIT(
    REPLACE(REPLACE(REPLACE(REPLACE(body, '.', ' '), ',', ' '),
            ';', ' '), '?', ' '), ' ')
WHERE LEN(value) >= 5
GROUP BY LOWER(value)
HAVING COUNT(*) >= 20;
GO

/*  Baseline from a matched random sample of the same era.     */
DROP TABLE IF EXISTS #base;

SELECT TOP 2000 s.body
INTO #base
FROM dbo.speech_role r
JOIN dbo.speech s ON s.speech_id = r.speech_id
WHERE r.role <> 'chair' AND r.speech_date < '2001-06-07'
  AND LEN(s.body) > 1500
ORDER BY NEWID();

DROP TABLE IF EXISTS #basewords;

SELECT w = LOWER(value), n = COUNT(*)
INTO #basewords
FROM #base CROSS APPLY STRING_SPLIT(
    REPLACE(REPLACE(REPLACE(REPLACE(body, '.', ' '), ',', ' '),
            ';', ' '), '?', ' '), ' ')
WHERE LEN(value) >= 5
GROUP BY LOWER(value);
GO

SELECT TOP 40
       word = b.w,
       benn_uses = b.n,
       benn_rate = CAST(1000000.0 * b.n / (SELECT SUM(n) FROM #bwords) AS DECIMAL(10,1)),
       house_rate = CAST(1000000.0 * ISNULL(h.n, 0)
                         / (SELECT SUM(n) FROM #basewords) AS DECIMAL(10,1)),
       ratio = CAST((1.0 * b.n / (SELECT SUM(n) FROM #bwords))
                  / NULLIF(1.0 * ISNULL(h.n, 1) / (SELECT SUM(n) FROM #basewords), 0)
                    AS DECIMAL(8,2))
FROM #bwords b
LEFT JOIN #basewords h ON h.w = b.w
WHERE b.n >= 30
ORDER BY ratio DESC;
GO

/*==============================================================
  6. Who did he sound like?

  Nearest MPs to Benn's own centroid. Not who he agreed with -
  the embeddings cannot see that, as established at length - but
  who occupied the same territory.
==============================================================*/
DROP TABLE IF EXISTS #others;

SELECT r.speaker_name, s.speech_id,
       rn = ROW_NUMBER() OVER (PARTITION BY r.speaker_name ORDER BY NEWID())
INTO #others
FROM dbo.speech_role r
JOIN dbo.speech s ON s.speech_id = r.speech_id
WHERE r.role <> 'chair' AND r.speech_date < '2001-06-07'
  AND r.speaker_name IS NOT NULL AND r.speaker_name <> 'Unknown'
  AND CHARINDEX('Benn', r.speaker_name) = 0
  AND LEN(s.body) > 1500;
GO

SELECT TOP 25
       o.speaker_name,
       party = MIN(sp.main_party),
       speeches_compared = COUNT(*),
       distance = CAST(AVG(VECTOR_DISTANCE('cosine',
                       bv.embedding, ov.embedding)) AS DECIMAL(6,4))
FROM #others o
JOIN #bsample b ON 1 = 1
JOIN dbo.speech_vec ov ON ov.speech_id = o.speech_id
JOIN dbo.speech_vec bv ON bv.speech_id = b.speech_id
LEFT JOIN dbo.speaker_party sp ON sp.speaker_name = o.speaker_name
WHERE o.rn <= 20
GROUP BY o.speaker_name
HAVING COUNT(*) >= 300
ORDER BY AVG(VECTOR_DISTANCE('cosine', bv.embedding, ov.embedding));
GO
