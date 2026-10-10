/*==============================================================
  HANSARD - PHRASE ADOPTION, SECOND PASS

  No Python re-run needed. dbo.phrase already holds the 1,086,386
  candidates; everything wrong with v1 was in the interpretation,
  not the extraction.

  FOUR THINGS WERE WRONG

  1. SHINGLES. A 6-gram window slid along one piece of text
     produces dozens of overlapping "phrases". Peter Bone read a
     petition about the Badman report into the record 144 times
     and it generated eighteen of the top forty results. All
     shingles of one source share the same first_speech, so
     collapsing on (first_speech, last_speech) reduces one
     petition to one row.

  2. MEMBER REFERENCES. "the hon. Member for Roxburgh (Mr.
     Kirkwood)" is the House's address convention, not a
     coinage. It bursts because a career is time-bounded. These
     dominate the list.

  3. DATED BOILERPLATE. "order 1995 which was laid before this"
     has burstiness 0.870 because the YEAR IS IN THE PHRASE. The
     filter was rewarding phrases that contained their own date.

  4. NAME VARIANTS. "Mr. Calum A. Macdonald" and "Mr. Calum
     Macdonald" are one man, so the different-speaker filter let
     him quote himself. Ministers appear as "The Minister of
     State, X (Mr. Y)", so the surname has to come out of the
     brackets first.

  The headline number from v1 stands and does not depend on any
  of this - it is a ratio of two counts computed the same way:
  opposition coinages reach a minister 2.23% of the time,
  government coinages 3.83%. Section 1 re-tests it under the
  stricter filters to see whether it survives.
==============================================================*/

USE HANSARD;
GO
SET NOCOUNT ON;
GO

/*==============================================================
  0. A CLEAN PHRASE TABLE

  Everything downstream reads from this. Three exclusions, then
  the de-shingle.
==============================================================*/
DROP TABLE IF EXISTS dbo.phrase_clean;
GO

/*  Speaker surname. Ministers are recorded as
    "The Minister of State, Home Office (Mrs. Angela Rumbold)",
    backbenchers as "Mr. Frank Dobson". Take what is inside the
    brackets when there are brackets, then the last word.      */
CREATE OR ALTER FUNCTION dbo.surname (@n NVARCHAR(400))
RETURNS NVARCHAR(100) WITH SCHEMABINDING
AS
BEGIN
    IF @n IS NULL RETURN NULL;

    DECLARE @s NVARCHAR(400) = @n;

    /*  Inside the brackets, if any.  */
    IF CHARINDEX('(', @s) > 0
        SET @s = SUBSTRING(@s, CHARINDEX('(', @s) + 1, 400);
    SET @s = REPLACE(REPLACE(@s, ')', ''), ':', '');

    /*  Strip a trailing "I beg to move," and similar - one row
        in your results had it welded on.                       */
    IF CHARINDEX(',', @s) > 0 AND CHARINDEX(' beg ', @s) > 0
        SET @s = LEFT(@s, CHARINDEX(',', @s) - 1);

    SET @s = LTRIM(RTRIM(REPLACE(@s, NCHAR(160), N' ')));

    /*  Last whitespace-delimited token.  */
    IF CHARINDEX(' ', REVERSE(@s)) > 0
        SET @s = RIGHT(@s, CHARINDEX(' ', REVERSE(@s)) - 1);

    SET @s = REPLACE(REPLACE(@s, '.', ''), ',', '');
    RETURN LOWER(LTRIM(RTRIM(@s)));
END
GO

;WITH filtered AS
(
    SELECT p.*
    FROM dbo.phrase p
    WHERE
        /*  (2) Member-reference formulae. The House's way of
            naming people, not anybody's coinage.               */
            CHARINDEX('member for',   p.phrase) = 0
        AND CHARINDEX('hon member',   p.phrase) = 0
        AND CHARINDEX('right hon',    p.phrase) = 0
        AND CHARINDEX('hon friend',   p.phrase) = 0
        AND CHARINDEX('learned member', p.phrase) = 0
        AND CHARINDEX('the member',   p.phrase) = 0

        /*  (3) Procedural furniture and dated boilerplate.
            Anything containing a four-digit year is excluded
            outright - the burstiness score for those is an
            artefact of the year being inside the phrase.       */
        AND CHARINDEX('laid before',    p.phrase) = 0
        AND CHARINDEX('copy of which',  p.phrase) = 0
        AND CHARINDEX('beg to move',    p.phrase) = 0
        AND CHARINDEX('take note of',   p.phrase) = 0
        AND CHARINDEX('have power to',  p.phrase) = 0
        AND CHARINDEX('shall have power', p.phrase) = 0
        AND CHARINDEX('be read a second', p.phrase) = 0
        AND CHARINDEX('committee of the whole', p.phrase) = 0
        AND CHARINDEX('as the case may be', p.phrase) = 0
        AND p.phrase NOT LIKE '%19[0-9][0-9]%'
        AND p.phrase NOT LIKE '%20[0-9][0-9]%'

        /*  Secretary-of-State titles are furniture too.        */
        AND CHARINDEX('secretary of state for', p.phrase) = 0
        AND CHARINDEX('under-secretary', p.phrase) = 0
),
deshingled AS
(
    /*  (1) One row per source pair. All shingles of one piece of
        text share first_speech, so this collapses a petition
        read 144 times into a single candidate.                 */
    SELECT *, rn = ROW_NUMBER() OVER (
                   PARTITION BY first_speech, last_speech
                   ORDER BY uses DESC, burstiness DESC)
    FROM filtered
)
SELECT phrase_hash, phrase, uses, burstiness,
       first_speech, last_speech, first_year, last_year
INTO dbo.phrase_clean
FROM deshingled WHERE rn = 1;
GO

CREATE INDEX ix_pc_first ON dbo.phrase_clean (first_speech);
CREATE INDEX ix_pc_last  ON dbo.phrase_clean (last_speech);
GO

SELECT stage = 'raw',        phrases = COUNT(*) FROM dbo.phrase
UNION ALL
SELECT 'after filtering and de-shingling', COUNT(*) FROM dbo.phrase_clean;
GO


/*==============================================================
  ATTRIBUTION, with the surname fix

  Petitions and prayers are excluded here rather than above:
  reading a petition into the record is not coining a phrase,
  and PETITIONS was the single biggest source of junk.
==============================================================*/
DROP TABLE IF EXISTS dbo.phrase_attr2;
GO

SELECT p.phrase_hash, p.phrase, p.uses, p.burstiness,
       p.first_year, p.last_year,
       span_years   = p.last_year - p.first_year,

       coiner       = a.speaker_name,
       coiner_sn    = dbo.surname(a.speaker_name),
       coiner_party = a.party,
       coiner_role  = a.role,
       coiner_side  = CASE WHEN a.party = a.gov_party THEN 'gov' ELSE 'opp' END,
       coined_on    = a.speech_date,
       coined_in    = a.major_heading,

       later_who    = b.speaker_name,
       later_sn     = dbo.surname(b.speaker_name),
       later_party  = b.party,
       later_role   = b.role,
       later_side   = CASE WHEN b.party = b.gov_party THEN 'gov' ELSE 'opp' END,
       later_on     = b.speech_date,
       later_in     = b.major_heading,

       lag_days     = DATEDIFF(day, a.speech_date, b.speech_date)
INTO dbo.phrase_attr2
FROM dbo.phrase_clean p
JOIN dbo.speech_role a ON a.speech_id = p.first_speech
JOIN dbo.speech_role b ON b.speech_id = p.last_speech
WHERE a.role <> 'chair' AND b.role <> 'chair'
  AND a.speaker_name IS NOT NULL AND b.speaker_name IS NOT NULL
  AND a.speaker_name <> 'Unknown' AND b.speaker_name <> 'Unknown'
  AND a.speaker_name <> 'Hon. Members'

  /*  (4) Surname comparison, so name variants of one person do
      not read as adoption.                                     */
  AND dbo.surname(a.speaker_name) <> dbo.surname(b.speaker_name)

  /*  Petitions are recitation, not coinage.                    */
  AND CHARINDEX('PETITION', UPPER(REPLACE(a.major_heading, NCHAR(160), N' '))) = 0
  AND CHARINDEX('PRAYERS',  UPPER(REPLACE(a.major_heading, NCHAR(160), N' '))) = 0;
GO

CREATE INDEX ix_pa2 ON dbo.phrase_attr2 (coiner_side, later_role);
GO

SELECT usable_phrases = COUNT(*) FROM dbo.phrase_attr2;
GO


/*==============================================================
  1. THE HEADLINE, RE-TESTED

  v1 said 2.23% versus 3.83%. If the ratio holds under the
  stricter filters, the negative result is real and not an
  artefact of procedural noise.
==============================================================*/
WITH coined AS
(
    SELECT coiner_side, phrases = COUNT(*)
    FROM dbo.phrase_attr2 GROUP BY coiner_side
),
crossed AS
(
    SELECT coiner_side, to_minister = COUNT(*)
    FROM dbo.phrase_attr2
    WHERE later_role = 'minister' AND lag_days > 180
    GROUP BY coiner_side
)
SELECT c.coiner_side,
       coined = c.phrases,
       reached_a_minister = x.to_minister,
       pct = CAST(100.0 * x.to_minister / c.phrases AS DECIMAL(5,2))
FROM coined c JOIN crossed x ON x.coiner_side = c.coiner_side;
GO

/*  And the four-way direction table, normalised. Raw counts are
    meaningless because the government side speaks more - the
    rate per coinage is the only comparable figure.             */
WITH base AS
(
    SELECT coiner_side, coined = COUNT(*)
    FROM dbo.phrase_attr2 GROUP BY coiner_side
),
dirs AS
(
    SELECT coiner_side, later_side, n = COUNT(*)
    FROM dbo.phrase_attr2 WHERE lag_days > 180
    GROUP BY coiner_side, later_side
)
SELECT direction = d.coiner_side + ' -> ' + d.later_side,
       phrases = d.n,
       coinages_by_that_side = b.coined,
       pct = CAST(100.0 * d.n / b.coined AS DECIMAL(5,2))
FROM dirs d JOIN base b ON b.coiner_side = d.coiner_side
ORDER BY pct DESC;
GO


/*==============================================================
  2. THE READABLE LIST

  Opposition coinage, minister's mouth, different party,
  different person, at least six months later, and none of the
  procedural categories. This is the list to actually read -
  thirty rows a human can judge.
==============================================================*/
SELECT TOP 40
       pa.phrase,
       pa.uses,
       burst = pa.burstiness,
       pa.coiner, pa.coiner_party, pa.coined_on,
       coined_debate = LEFT(REPLACE(pa.coined_in, NCHAR(160), N' '), 50),
       pa.later_who, pa.later_party, pa.later_on,
       years_later = CAST(pa.lag_days / 365.25 AS DECIMAL(5,1))
FROM dbo.phrase_attr2 pa
WHERE pa.coiner_side  = 'opp'
  AND pa.later_role   = 'minister'
  AND pa.lag_days     > 180
  AND pa.coiner_party <> pa.later_party
ORDER BY pa.uses DESC, pa.burstiness DESC;
GO

/*  The same thing the other way, as the control. Read both. If
    they look equally like genuine adoption, there is no story
    in the direction - and that is a finding too.               */
SELECT TOP 40
       pa.phrase, pa.uses, burst = pa.burstiness,
       pa.coiner, pa.coiner_party, pa.coined_on,
       pa.later_who, pa.later_party, pa.later_on,
       years_later = CAST(pa.lag_days / 365.25 AS DECIMAL(5,1))
FROM dbo.phrase_attr2 pa
WHERE pa.coiner_side  = 'gov'
  AND pa.later_role   = 'minister'
  AND pa.lag_days     > 180
  AND pa.coiner_party <> pa.later_party
ORDER BY pa.uses DESC, pa.burstiness DESC;
GO


/*==============================================================
  3. THE COINERS, cleaned up

  v1 had "Unknown" at the top with 18,422 phrases and Theresa May
  with 2,808 reaching zero ministers - which is just an artefact
  of her speaking late in the corpus with no time left for anyone
  to adopt anything. Normalising by career window fixes that.
==============================================================*/
WITH career AS
(
    SELECT speaker_name,
           first_seen = MIN(speech_date),
           last_seen  = MAX(speech_date),
           speeches   = COUNT(*)
    FROM dbo.speech_role
    WHERE role <> 'chair' AND speaker_name IS NOT NULL
    GROUP BY speaker_name
)
SELECT TOP 30
       pa.coiner,
       party = MIN(pa.coiner_party),
       phrases_coined = COUNT(*),
       speeches = MIN(c.speeches),
       per_1k_speeches = CAST(1000.0 * COUNT(*) / MIN(c.speeches) AS DECIMAL(8,1)),
       reached_minister = SUM(CASE WHEN pa.later_role = 'minister' THEN 1 ELSE 0 END),
       /*  Years of corpus left after their last speech - a
           coiner who arrives in 2019 has no runway.            */
       runway_years = CAST(DATEDIFF(day, MAX(c.last_seen), '2021-12-31')
                           / 365.25 AS DECIMAL(5,1))
FROM dbo.phrase_attr2 pa
JOIN career c ON c.speaker_name = pa.coiner
GROUP BY pa.coiner
HAVING COUNT(*) >= 20 AND MIN(c.speeches) >= 200
ORDER BY 1000.0 * COUNT(*) / MIN(c.speeches) DESC;
GO

/*  By party, normalised by WORDS not speeches.

    v1 put the Liberals at 10,383 phrases per 10,000 speeches -
    more than one coinage per speech, which should have been a
    red flag. More words means more 6-gram windows means more
    chances to coin, and the Liberals of 1979-88 gave long
    set-piece speeches. Words is the honest denominator.        */
WITH spoke AS
(
    SELECT r.party,
           speeches = COUNT(*),
           words = SUM(CAST(LEN(s.body) - LEN(REPLACE(s.body,' ','')) + 1 AS BIGINT))
    FROM dbo.speech_role r
    JOIN dbo.speech s ON s.speech_id = r.speech_id
    WHERE r.role <> 'chair'
    GROUP BY r.party
)
SELECT pa.coiner_party,
       phrases = COUNT(*),
       speeches = MIN(k.speeches),
       million_words = CAST(MIN(k.words) / 1000000.0 AS DECIMAL(8,2)),
       per_million_words = CAST(1000000.0 * COUNT(*) / MIN(k.words) AS DECIMAL(8,1))
FROM dbo.phrase_attr2 pa
JOIN spoke k ON k.party = pa.coiner_party
GROUP BY pa.coiner_party
HAVING MIN(k.speeches) >= 5000
ORDER BY 1000000.0 * COUNT(*) / MIN(k.words) DESC;
GO


/*==============================================================
  4. WHAT SURVIVED THE CUT

  Sanity check. If sections 2 and 3 still look like furniture,
  the honest conclusion is that 6-gram burstiness cannot
  distinguish a coined political formulation from a recurring
  parliamentary one, and the negative result in section 1 is all
  this method can deliver.

  Which is fine. Two methods, two honest noes, and a reason for
  each - that is a better article than one method and a maybe.
==============================================================*/
SELECT sample = 'random 30 from the cleaned set',
       phrase, uses, burstiness, coiner, coiner_party, first_year
FROM (SELECT TOP 30 * FROM dbo.phrase_attr2 ORDER BY NEWID()) z
ORDER BY uses DESC;
GO

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
