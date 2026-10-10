/*==============================================================
  HANSARD CURIOSITIES - v3

  The markers are real. [Interruption.] is in 39,163 speeches and
  "Interruption" in any form 47,030, so the LIKE wildcards were
  hiding a genuine signal, not an absent one.

  THREE FINDINGS THAT STAND

  - Ministers are interrupted 4.222% of the time against 2.738%
    for backbenchers. Office invites the shouting rather than
    protecting you from it.
  - Giving way has collapsed from 1.801% of speeches in the 1990s
    to 0.362% in the 2020s, and the decline predates the
    pandemic - the 2010s were already at half the 1990s rate.
  - The most-interrupted list is Kinnock, Miliband, Osborne,
    Blair, Starmer, Corbyn, Prescott, Benn. It is a prominence
    ranking, not an unpopularity one.

  TWO BUGS FIXED HERE

  1. MIN(party) picks alphabetically, so one mislabelled row
     reassigns a career. Tony Banks came out Conservative; he was
     Labour. 'Conservative' < 'Labour', so a single bad row won.
     Replaced with the modal party.

  2. The crossover query was measuring a property of the
     reference samples. to_con < to_lab for EVERY speaker,
     Labour ones included, because the Conservative reference set
     is topically broader - 851,967 Conservative speeches against
     553,250 Labour, and more years in office means more subjects
     covered. So to_con - to_lab flipped sign on party membership
     by construction and the two leaderboards were one artefact
     printed twice. Fixed by centring within party.
==============================================================*/

USE HANSARD;
GO
SET NOCOUNT ON;
GO

/*==============================================================
  0. MODAL PARTY, and a surname key

  Every leaderboard downstream joins to this instead of taking
  MIN(party).
==============================================================*/
DROP TABLE IF EXISTS dbo.speaker_party;
GO

WITH pc AS
(
    SELECT speaker_name, party, n = COUNT(*),
           rn = ROW_NUMBER() OVER (PARTITION BY speaker_name
                                   ORDER BY COUNT(*) DESC, party)
    FROM dbo.speech_role
    WHERE role <> 'chair' AND party IS NOT NULL
      AND speaker_name IS NOT NULL AND speaker_name <> 'Unknown'
    GROUP BY speaker_name, party
)
SELECT speaker_name,
       main_party = party,
       rows_in_main = n
INTO dbo.speaker_party
FROM pc WHERE rn = 1;
GO

CREATE UNIQUE CLUSTERED INDEX ix_speaker_party
    ON dbo.speaker_party (speaker_name);
GO

ALTER TABLE dbo.speaker_party
  ADD CONSTRAINT pk_speaker_party PRIMARY KEY (speaker_name);
GO

/*  How bad was the mislabelling? Any speaker whose modal party
    differs from MIN(party) was misattributed in v2.           */
SELECT misattributed_speakers = COUNT(*)
FROM (
    SELECT r.speaker_name,
           min_party = MIN(r.party),
           modal = MIN(sp.main_party)
    FROM dbo.speech_role r
    JOIN dbo.speaker_party sp ON sp.speaker_name = r.speaker_name
    WHERE r.role <> 'chair' AND r.party IS NOT NULL
    GROUP BY r.speaker_name
    HAVING MIN(r.party) <> MIN(sp.main_party)
) z;
GO

/*  The worst offenders, for the record. Tony Banks should be
    in here.                                                   */
SELECT TOP 20 r.speaker_name,
       speeches = COUNT(*),
       min_party_was = MIN(r.party),
       actually = MIN(sp.main_party),
       distinct_labels = COUNT(DISTINCT r.party)
FROM dbo.speech_role r
JOIN dbo.speaker_party sp ON sp.speaker_name = r.speaker_name
WHERE r.role <> 'chair' AND r.party IS NOT NULL
GROUP BY r.speaker_name
HAVING MIN(r.party) <> MIN(sp.main_party)
ORDER BY COUNT(*) DESC;
GO


/*==============================================================
  1. REACTION, with the unbracketed variants caught

  [Laughter.] is 2,626 but "Laughter" anywhere is 8,833, so the
  bracketed-with-full-stop form is a minority of the real total.
  Matching the bare word catches [Laughter], (Laughter) and the
  inline forms. It will also catch an MP using the word in a
  sentence, which is a small overcount I will take over missing
  two thirds of the data.
==============================================================*/
DROP TABLE IF EXISTS #reaction;

SELECT r.speech_id, r.speaker_name, r.role, r.speech_date,
       party      = sp.main_party,
       words      = LEN(s.body) - LEN(REPLACE(s.body, ' ', '')) + 1,
       laughter   = CASE WHEN CHARINDEX('Laughter', s.body)     > 0 THEN 1 ELSE 0 END,
       interrupt  = CASE WHEN CHARINDEX('Interruption', s.body)  > 0 THEN 1 ELSE 0 END,
       hearhear   = CASE WHEN CHARINDEX('Hear, hear', s.body)    > 0 THEN 1 ELSE 0 END,
       gaveway    = CASE WHEN CHARINDEX('give way', s.body)      > 0 THEN 1 ELSE 0 END,
       rubbish    = CASE WHEN CHARINDEX('Rubbish', s.body)       > 0 THEN 1 ELSE 0 END
INTO #reaction
FROM dbo.speech_role r
JOIN dbo.speech s        ON s.speech_id   = r.speech_id
JOIN dbo.speaker_party sp ON sp.speaker_name = r.speaker_name
WHERE r.role <> 'chair';

CREATE INDEX ix_reaction ON #reaction (speaker_name);
GO

/*  Funniest MPs, correct parties.  */
SELECT TOP 25 r.speaker_name, r.party,
       speeches = COUNT(*), laughs = SUM(r.laughter),
       pct_funny = CAST(100.0 * SUM(r.laughter) / COUNT(*) AS DECIMAL(5,2))
FROM #reaction r
GROUP BY r.speaker_name, r.party
HAVING COUNT(*) >= 200 AND SUM(r.laughter) >= 8
ORDER BY 100.0 * SUM(r.laughter) / COUNT(*) DESC;
GO

/*  Most interrupted.  */
SELECT TOP 25 r.speaker_name, r.party,
       speeches = COUNT(*), interrupted = SUM(r.interrupt),
       pct = CAST(100.0 * SUM(r.interrupt) / COUNT(*) AS DECIMAL(5,2))
FROM #reaction r
GROUP BY r.speaker_name, r.party
HAVING COUNT(*) >= 200 AND SUM(r.interrupt) >= 10
ORDER BY 100.0 * SUM(r.interrupt) / COUNT(*) DESC;
GO

/*  Surname rollup, so Kinnock's two name forms become one man.
    APPROXIMATE - it conflates every Smith and Brown in the
    House, so read name_forms before believing a row.          */
SELECT TOP 25
       surname = dbo.surname(r.speaker_name),
       name_forms = COUNT(DISTINCT r.speaker_name),
       party = MIN(r.party),
       speeches = COUNT(*),
       interrupted = SUM(r.interrupt),
       pct = CAST(100.0 * SUM(r.interrupt) / COUNT(*) AS DECIMAL(5,2))
FROM #reaction r
GROUP BY dbo.surname(r.speaker_name)
HAVING COUNT(*) >= 300 AND COUNT(DISTINCT r.party) = 1
ORDER BY 100.0 * SUM(r.interrupt) / COUNT(*) DESC;
GO


/*==============================================================
  2. THE DEATH OF GIVING WAY

  By year rather than decade, because the decade view hides
  whether this is a trend or a step change. Watch 2020-21 for
  the hybrid-proceedings cliff - you cannot intervene on
  somebody appearing by video link.
==============================================================*/
SELECT yr = YEAR(speech_date),
       speeches = COUNT(*),
       pct_giveway   = CAST(100.0 * SUM(gaveway)   / COUNT(*) AS DECIMAL(6,3)),
       pct_interrupt = CAST(100.0 * SUM(interrupt) / COUNT(*) AS DECIMAL(6,3)),
       pct_laughter  = CAST(100.0 * SUM(laughter)  / COUNT(*) AS DECIMAL(6,3)),
       pct_hearhear  = CAST(100.0 * SUM(hearhear)  / COUNT(*) AS DECIMAL(6,3)),
       avg_words     = CAST(AVG(words * 1.0) AS DECIMAL(8,1))
FROM #reaction
GROUP BY YEAR(speech_date)
HAVING COUNT(*) >= 2000
ORDER BY yr;
GO

/*  Is it the speeches getting shorter, or the House getting
    less tolerant of interruption? If giving way per thousand
    words has fallen as much as giving way per speech, it is
    behaviour. If not, it is just shorter speeches.            */
SELECT decade = (YEAR(speech_date) / 10) * 10,
       speeches = COUNT(*),
       avg_words = CAST(AVG(words * 1.0) AS DECIMAL(8,1)),
       giveway_per_speech = CAST(100.0 * SUM(gaveway) / COUNT(*) AS DECIMAL(6,3)),
       giveway_per_100k_words = CAST(100000.0 * SUM(gaveway)
                / SUM(CAST(words AS BIGINT)) AS DECIMAL(8,2))
FROM #reaction
GROUP BY (YEAR(speech_date) / 10) * 10
ORDER BY decade;
GO


/*==============================================================
  3. CROSSOVER, CENTRED

  The previous version compared every speaker against zero, and
  zero is the wrong origin because the two reference samples are
  not equally broad. Centring within party asks the right
  question: does this MP sit further from their own side than
  their colleagues do?
==============================================================*/
DROP TABLE IF EXISTS #sample;

WITH eligible AS
(
    SELECT speaker_name
    FROM dbo.speech_role
    WHERE role <> 'chair' AND speaker_name IS NOT NULL
      AND speaker_name <> 'Unknown'
    GROUP BY speaker_name
    HAVING COUNT(*) >= 100
),
picked AS
(
    SELECT r.speaker_name, r.speech_id,
           rn = ROW_NUMBER() OVER (PARTITION BY r.speaker_name
                                   ORDER BY NEWID())
    FROM dbo.speech_role r
    JOIN eligible e ON e.speaker_name = r.speaker_name
    JOIN dbo.speech s ON s.speech_id = r.speech_id
    WHERE r.role <> 'chair' AND LEN(s.body) > 1000
)
SELECT p.speaker_name, p.speech_id, party = sp.main_party
INTO #sample
FROM picked p
JOIN dbo.speaker_party sp ON sp.speaker_name = p.speaker_name
WHERE p.rn <= 30;

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

DROP TABLE IF EXISTS #gap;

WITH scored AS
(
    SELECT s.speaker_name, ref_party = f.party,
           d = AVG(VECTOR_DISTANCE('cosine', sv.embedding, fv.embedding))
    FROM #sample s
    CROSS JOIN #ref f
    JOIN dbo.speech_vec sv ON sv.speech_id = s.speech_id
    JOIN dbo.speech_vec fv ON fv.speech_id = f.speech_id
    WHERE s.party IN ('Conservative', 'Labour')
    GROUP BY s.speaker_name, f.party
)
SELECT sc.speaker_name,
       own_party = MIN(s.party),
       to_con = MAX(CASE WHEN sc.ref_party = 'Conservative' THEN sc.d END),
       to_lab = MAX(CASE WHEN sc.ref_party = 'Labour'       THEN sc.d END)
INTO #gap
FROM scored sc
JOIN #sample s ON s.speaker_name = sc.speaker_name
GROUP BY sc.speaker_name;
GO

/*  The thing that proves the old query was broken: if to_con is
    below to_lab for Labour members too, the gap is a property of
    the reference sets.                                        */
SELECT own_party, mps = COUNT(*),
       mean_to_con = CAST(AVG(to_con) AS DECIMAL(6,4)),
       mean_to_lab = CAST(AVG(to_lab) AS DECIMAL(6,4)),
       mean_raw_gap = CAST(AVG(to_con - to_lab) AS DECIMAL(7,5)),
       sd_raw_gap   = CAST(STDEV(to_con - to_lab) AS DECIMAL(7,5))
FROM #gap GROUP BY own_party;
GO

/*  Centred. z is how far this MP's gap sits from their own
    party's mean, in party standard deviations. Sign is flipped
    for Labour so that in both cases a high score means "further
    from my own side than my colleagues are".                  */
WITH stats AS
(
    SELECT own_party,
           m  = AVG(to_con - to_lab),
           sd = STDEV(to_con - to_lab)
    FROM #gap GROUP BY own_party
),
z AS
(
    SELECT g.speaker_name, g.own_party,
           to_con = CAST(g.to_con AS DECIMAL(6,4)),
           to_lab = CAST(g.to_lab AS DECIMAL(6,4)),
           score = CASE WHEN g.own_party = 'Conservative' THEN 1 ELSE -1 END
                   * ((g.to_con - g.to_lab) - st.m) / NULLIF(st.sd, 0)
    FROM #gap g JOIN stats st ON st.own_party = g.own_party
)
SELECT TOP 30 speaker_name, own_party, to_con, to_lab,
       off_message_sd = CAST(score AS DECIMAL(6,2))
FROM z ORDER BY score DESC;
GO

/*  And the most tribal - the ones furthest from the other side
    relative to their own colleagues.                          */
WITH stats AS
(
    SELECT own_party, m = AVG(to_con - to_lab),
           sd = STDEV(to_con - to_lab)
    FROM #gap GROUP BY own_party
),
z AS
(
    SELECT g.speaker_name, g.own_party,
           to_con = CAST(g.to_con AS DECIMAL(6,4)),
           to_lab = CAST(g.to_lab AS DECIMAL(6,4)),
           score = CASE WHEN g.own_party = 'Conservative' THEN 1 ELSE -1 END
                   * ((g.to_con - g.to_lab) - st.m) / NULLIF(st.sd, 0)
    FROM #gap g JOIN stats st ON st.own_party = g.own_party
)
SELECT TOP 30 speaker_name, own_party, to_con, to_lab,
       on_message_sd = CAST(score AS DECIMAL(6,2))
FROM z ORDER BY score ASC;
GO

/*==============================================================
  NOTE ON WHAT THIS CAN AND CANNOT SAY

  Section 3 still rests on embeddings, which measure what a
  speech is ABOUT rather than what the speaker thinks of it.
  "Off message" here means an MP whose SUBJECTS resemble the
  other side's more than their colleagues' subjects do - a
  Conservative who spends their time on housing and poverty, say.
  That is a real and interesting thing to be able to measure. It
  is not the same as agreeing with the other side, and the
  adoption work already showed why the stronger claim will not
  stand up.
==============================================================*/


/*  If "on message" is really "short career", first_year and
    speech count will predict the score. If the correlation is
    weak, the cohort effect is real.                           */
SELECT decade_entered = (YEAR(c.first_seen) / 10) * 10,
       mps        = COUNT(*),
       mean_score = CAST(AVG(z.score) AS DECIMAL(6,3)),
       mean_career_years = CAST(AVG(DATEDIFF(day, c.first_seen,
                                   c.last_seen) / 365.25) AS DECIMAL(5,1)),
       mean_speeches     = CAST(AVG(c.speeches * 1.0) AS DECIMAL(8,0))
FROM #zscores z
JOIN (SELECT speaker_name, first_seen = MIN(speech_date),
             last_seen = MAX(speech_date), speeches = COUNT(*)
      FROM dbo.speech_role WHERE role <> 'chair'
      GROUP BY speaker_name) c ON c.speaker_name = z.speaker_name
GROUP BY (YEAR(c.first_seen) / 10) * 10
ORDER BY decade_entered;