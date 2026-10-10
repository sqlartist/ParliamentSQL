/*==============================================================
  WHERE IS MARGARET THATCHER?

  She appears exactly once in everything run so far, and only in
  the broken crossover query. The suspicion is that Hansard filed
  her under her office rather than her name - "The Prime
  Minister" is the second biggest coiner in the corpus after
  "Unknown", and it is not a person.

  If that is right, every analysis keyed on speaker_name has been
  quietly ignoring the single most consequential speaker of the
  period, and so has every other analysis of this dataset that
  anyone has ever published.
==============================================================*/

USE HANSARD;
GO
SET NOCOUNT ON;
GO

/*  1. Every name form that might be her.  */
SELECT speaker_name,
       party    = MIN(party),
       speeches = COUNT(*),
       first    = MIN(speech_date),
       last     = MAX(speech_date)
FROM dbo.speech_role
WHERE CHARINDEX('Thatcher', speaker_name) > 0
GROUP BY speaker_name
ORDER BY COUNT(*) DESC;
GO

/*  2. How the office is recorded across the whole period. If
    "The Prime Minister" bare dominates 1979-90 and the named
    form dominates later, the convention changed and it is
    Thatcher specifically who disappears.                      */
SELECT yr = YEAR(speech_date),
       pm_bare  = SUM(CASE WHEN speaker_name = 'The Prime Minister'
                           THEN 1 ELSE 0 END),
       pm_named = SUM(CASE WHEN speaker_name LIKE 'The Prime Minister (%'
                           THEN 1 ELSE 0 END),
       thatcher_by_name = SUM(CASE WHEN CHARINDEX('Thatcher', speaker_name) > 0
                                   THEN 1 ELSE 0 END)
FROM dbo.speech_role
WHERE speaker_name LIKE 'The Prime Minister%'
   OR CHARINDEX('Thatcher', speaker_name) > 0
GROUP BY YEAR(speech_date)
HAVING SUM(CASE WHEN speaker_name LIKE 'The Prime Minister%' THEN 1 ELSE 0 END) > 0
ORDER BY yr;
GO

/*  3. Resolve the office to the holder by date, then ask the
    questions she was excluded from.                           */
DROP TABLE IF EXISTS #pm;

SELECT r.speech_id, r.speech_date, r.speaker_name,
       holder = CASE
           WHEN r.speech_date <  '1990-11-28' THEN 'Thatcher'
           WHEN r.speech_date <  '1997-05-02' THEN 'Major'
           WHEN r.speech_date <  '2007-06-27' THEN 'Blair'
           WHEN r.speech_date <  '2010-05-11' THEN 'Brown'
           WHEN r.speech_date <  '2016-07-13' THEN 'Cameron'
           WHEN r.speech_date <  '2019-07-24' THEN 'May'
           WHEN r.speech_date <  '2022-09-06' THEN 'Johnson'
           ELSE 'later' END
INTO #pm
FROM dbo.speech_role r
WHERE r.speaker_name LIKE 'The Prime Minister%'
   OR CHARINDEX('Thatcher', r.speaker_name) > 0;

CREATE INDEX ix_pm ON #pm (speech_id);
GO

/*  Reaction, by prime minister. The question nobody has been
    able to ask: who did the House shout at most?              */
SELECT p.holder,
       speeches = COUNT(*),
       pct_interrupt = CAST(100.0 * SUM(CASE WHEN CHARINDEX('Interruption', s.body) > 0
                                             THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(6,3)),
       pct_laughter  = CAST(100.0 * SUM(CASE WHEN CHARINDEX('Laughter', s.body) > 0
                                             THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(6,3)),
       pct_hearhear  = CAST(100.0 * SUM(CASE WHEN CHARINDEX('Hear, hear', s.body) > 0
                                             THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(6,3)),
       avg_words = CAST(AVG((LEN(s.body) - LEN(REPLACE(s.body,' ','')) + 1) * 1.0)
                        AS DECIMAL(8,1))
FROM #pm p
JOIN dbo.speech s ON s.speech_id = p.speech_id
WHERE p.holder <> 'later'
GROUP BY p.holder
ORDER BY 100.0 * SUM(CASE WHEN CHARINDEX('Interruption', s.body) > 0
                          THEN 1 ELSE 0 END) / COUNT(*) DESC;
GO

/*  4. Self-similarity. Which prime minister repeated themselves
    most? Sample 40 speeches each and measure mean pairwise
    distance - the same method that found Ralph Howell.        */
DROP TABLE IF EXISTS #pmsample;

SELECT holder, speech_id
INTO #pmsample
FROM (
    SELECT p.holder, p.speech_id,
           rn = ROW_NUMBER() OVER (PARTITION BY p.holder ORDER BY NEWID())
    FROM #pm p
    JOIN dbo.speech s ON s.speech_id = p.speech_id
    WHERE p.holder <> 'later' AND LEN(s.body) > 1000
) z WHERE rn <= 40;
GO

SELECT a.holder,
       pairs = COUNT(*),
       self_distance = CAST(AVG(VECTOR_DISTANCE('cosine',
                            av.embedding, bv.embedding)) AS DECIMAL(6,4))
FROM #pmsample a
JOIN #pmsample b ON b.holder = a.holder AND b.speech_id > a.speech_id
JOIN dbo.speech_vec av ON av.speech_id = a.speech_id
JOIN dbo.speech_vec bv ON bv.speech_id = b.speech_id
GROUP BY a.holder
ORDER BY AVG(VECTOR_DISTANCE('cosine', av.embedding, bv.embedding));
GO

/*  5. Her coinages, such as they are. Everything attributed to
    "The Prime Minister" while she held the office.            */
SELECT TOP 40 pa.phrase, pa.uses, pa.burstiness,
       pa.coined_on,
       debate = LEFT(REPLACE(pa.coined_in, NCHAR(160), N' '), 50),
       pa.later_who, pa.later_party,
       years_later = CAST(pa.lag_days / 365.25 AS DECIMAL(5,1))
FROM dbo.phrase_attr2 pa
WHERE pa.coiner LIKE 'The Prime Minister%'
  AND pa.coined_on < '1990-11-28'
ORDER BY pa.uses DESC, pa.burstiness DESC;
GO
