/*==============================================================
  HANSARD - ARGUMENT ADOPTION, v3

  WHAT v2 HIT

  Every speech classified as 'minister'. The cause: the dataset's
  government_posts / opposition_posts / parliamentary_posts
  columns exist in the schema and are EMPTY - all 1,700,647 rows
  hold the literal string '[]'. The one piece of metadata that
  would have made this easy is a column header and nothing else.

  Also: '  BILL PRESENTED ' survived a NOT LIKE 'BILL%PRESENTED%'
  filter and survived LTRIM/RTRIM. Hansard uses non-breaking
  spaces (char 160), which neither trims nor anchors a LIKE.

  WHAT v3 DOES INSTEAD

  Hansard renders office-holders with their office:

      "The Secretary of State for the Home Department (Mr Hurd)"
      "The Minister of State, Home Office (Mr Patten)"

  Backbenchers are just "Mr. Smith". So ministers are detectable
  from the name. Shadow ministers are NOT - the convention only
  applies to actual office-holders - so the treatment arm changes
  shape:

      treatment   opposition-side non-minister -> minister
      control     government-side non-minister -> minister

  Both arms: same bill, 14-400 days apart, different people, no
  Chair, ending in a minister. The only difference is which side
  the first speaker sat on. That is a cleaner control than v2's
  minister-to-minister arm, which had ministers sharing a brief.

  CHECK SECTION 2 BEFORE TRUSTING ANYTHING. The naming convention
  weakened over time - Victoria Atkins winding up the Domestic
  Abuse Bill appears as plain "Victoria Atkins", not by office.
  Expect good coverage in the 80s and 90s, poor in the 2010s.
==============================================================*/

USE HANSARD;
GO
SET NOCOUNT ON;
GO

/*--------------------------------------------------------------
  0. Who was in government
--------------------------------------------------------------*/
DROP TABLE IF EXISTS dbo.gov_period;
GO
CREATE TABLE dbo.gov_period (
    date_from DATE NOT NULL,
    date_to   DATE NOT NULL,
    gov_party VARCHAR(50) NOT NULL);

INSERT dbo.gov_period VALUES
    ('1979-05-04', '1997-05-01', 'Conservative'),
    ('1997-05-02', '2010-05-10', 'Labour'),
    ('2010-05-11', '2020-12-31', 'Conservative');
GO

/*==============================================================
  1. Roles, from the speaker name

  Order matters. Chair is tested first and overrides everything,
  because the dataset keeps the occupant's original party and
  those speeches are procedural boilerplate that dominated the
  rankings in v1.
==============================================================*/
DROP TABLE IF EXISTS dbo.speech_role;
GO

SELECT s.speech_id,
       s.speech_date,
       s.party,
       s.speaker_name,
       s.major_heading,
       gov_party = g.gov_party,
       role = CASE
           WHEN s.party = 'Speaker'                           THEN 'chair'
           WHEN s.speaker_name LIKE '%Deputy Speaker%'        THEN 'chair'
           WHEN s.speaker_name LIKE '%Madam Speaker%'         THEN 'chair'
           WHEN s.speaker_name LIKE '%Mr. Speaker%'           THEN 'chair'
           WHEN s.speaker_name LIKE '%Mr Speaker%'            THEN 'chair'
           WHEN s.speaker_name LIKE '%Ways and Means%'        THEN 'chair'
           WHEN s.speaker_name LIKE '%Deputy Chairman%'       THEN 'chair'
           WHEN s.speaker_name LIKE 'The Chairman%'           THEN 'chair'

           /*  Office-holders. The leading "The " is what makes
               this work - an MP referred to as "Mr. Hurd" is a
               backbencher in that speech; "The Secretary of
               State ... (Mr Hurd)" is him at the despatch box. */
           WHEN s.speaker_name LIKE 'The Prime Minister%'          THEN 'minister'
           WHEN s.speaker_name LIKE 'The Secretary of State%'      THEN 'minister'
           WHEN s.speaker_name LIKE 'The Minister%'                THEN 'minister'
           WHEN s.speaker_name LIKE 'The Parliamentary%Secretary%' THEN 'minister'
           WHEN s.speaker_name LIKE 'The Under-Secretary%'         THEN 'minister'
           WHEN s.speaker_name LIKE '%Under-Secretary of State%('  THEN 'minister'
           WHEN s.speaker_name LIKE 'The Chancellor%'              THEN 'minister'
           WHEN s.speaker_name LIKE 'The Chief Secretary%'         THEN 'minister'
           WHEN s.speaker_name LIKE 'The Financial Secretary%'     THEN 'minister'
           WHEN s.speaker_name LIKE 'The Economic Secretary%'      THEN 'minister'
           WHEN s.speaker_name LIKE 'The Paymaster General%'       THEN 'minister'
           WHEN s.speaker_name LIKE 'The Attorney-General%'        THEN 'minister'
           WHEN s.speaker_name LIKE 'The Solicitor-General%'       THEN 'minister'
           WHEN s.speaker_name LIKE 'The Lord Advocate%'           THEN 'minister'
           WHEN s.speaker_name LIKE 'The Lord President%'          THEN 'minister'
           WHEN s.speaker_name LIKE 'The Lord Privy Seal%'         THEN 'minister'
           WHEN s.speaker_name LIKE 'Mr. Secretary %'              THEN 'minister'

           ELSE 'member' END
INTO dbo.speech_role
FROM dbo.speech s
LEFT JOIN dbo.gov_period g
       ON s.speech_date BETWEEN g.date_from AND g.date_to;

CREATE INDEX ix_speech_role ON dbo.speech_role (role, speech_date)
    INCLUDE (speech_id, party, gov_party);
GO

SELECT role, speeches = COUNT(*),
       pct = CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2))
FROM dbo.speech_role GROUP BY role ORDER BY COUNT(*) DESC;
GO

/*==============================================================
  2. COVERAGE CHECK - read this before anything else

  Roughly 5-10% of speeches should be ministerial, and the share
  should be reasonably stable across decades. If the 2010s show
  near zero, the naming convention has broken down there and the
  analysis has to be restricted to the earlier period. Say so in
  the write-up rather than averaging over a period where the
  detector does not work.
==============================================================*/
SELECT decade = (YEAR(speech_date) / 10) * 10,
       speeches  = COUNT(*),
       ministers = SUM(CASE WHEN role = 'minister' THEN 1 ELSE 0 END),
       pct_min   = CAST(100.0 * SUM(CASE WHEN role = 'minister' THEN 1 ELSE 0 END)
                        / COUNT(*) AS DECIMAL(5,2)),
       chair     = SUM(CASE WHEN role = 'chair' THEN 1 ELSE 0 END)
FROM dbo.speech_role
GROUP BY (YEAR(speech_date) / 10) * 10
ORDER BY decade;
GO

/*  Spot-check that the detector caught real ministers.  */
SELECT TOP 25 speaker_name, speeches = COUNT(*)
FROM dbo.speech_role WHERE role = 'minister'
GROUP BY speaker_name ORDER BY COUNT(*) DESC;
GO

/*==============================================================
  3. Bills, with the non-breaking spaces dealt with
==============================================================*/
DROP TABLE IF EXISTS dbo.bill_speech;
GO

WITH flat AS
(
    /*  char 160 and tabs become ordinary spaces FIRST. Without
        this, LTRIM/RTRIM do nothing and LIKE anchors never
        match, which is how 'BILL PRESENTED' survived its own
        exclusion filter in v2.                                 */
    SELECT r.*,
           h = REPLACE(REPLACE(r.major_heading, NCHAR(160), N' '),
                       NCHAR(9), N' ')
    FROM dbo.speech_role r
    WHERE r.major_heading LIKE '%Bill%'
      AND r.gov_party IS NOT NULL
),
stripped AS
(
    SELECT speech_id, speech_date, party, speaker_name, role, gov_party,
           raw = LTRIM(RTRIM(
                   REPLACE(REPLACE(REPLACE(REPLACE(
                     CASE WHEN CHARINDEX(N'—', h) > 0
                          THEN SUBSTRING(h, CHARINDEX(N'—', h) + 1, 500)
                          ELSE h END,
                   '[Lords]', ''), '[ Lords ]', ''),
                   'Orders of the Day', ''), '(By Order)', '')))
    FROM flat
),
squeezed AS
(
    SELECT *, bill = UPPER(LTRIM(RTRIM(
                REPLACE(REPLACE(REPLACE(raw,'   ',' '),'  ',' '),'  ',' '))))
    FROM stripped
)
SELECT speech_id, speech_date, party, speaker_name, role, gov_party, bill,
       side = CASE
                WHEN party = gov_party                       THEN 'gov'
                WHEN party IN ('Labour (Co-op)')
                     AND gov_party = 'Labour'                THEN 'gov'
                ELSE 'opp' END
INTO dbo.bill_speech
FROM squeezed
WHERE LEN(bill) > 6
  AND bill NOT LIKE 'BILL%PRESENTED%'
  AND bill NOT LIKE 'BILLS%PRESENTED%'
  AND bill NOT LIKE 'CLAUSE %'
  AND bill NOT LIKE 'NEW CLAUSE%'
  AND bill NOT LIKE 'SCHEDULE %'
  AND bill NOT LIKE '%PRIVATE BUSINESS%'
  AND bill LIKE '%BILL%';

CREATE INDEX ix_bill_speech ON dbo.bill_speech (bill, speech_date)
    INCLUDE (speech_id, role, side);
GO

SELECT bills = COUNT(DISTINCT bill), speeches = COUNT(*) FROM dbo.bill_speech;

SELECT TOP 20 bill, speeches = COUNT(*),
       sitting_days = COUNT(DISTINCT speech_date),
       ministers = SUM(CASE WHEN role = 'minister' THEN 1 ELSE 0 END),
       gov_members = SUM(CASE WHEN role = 'member' AND side = 'gov' THEN 1 ELSE 0 END),
       opp_members = SUM(CASE WHEN role = 'member' AND side = 'opp' THEN 1 ELSE 0 END)
FROM dbo.bill_speech
GROUP BY bill
HAVING COUNT(DISTINCT speech_date) > 1
ORDER BY COUNT(*) DESC;
GO

/*==============================================================
  4. Pairs - treatment and control from one query

  Both arms end in a minister on the same bill, 14-400 days
  later, spoken by someone else. The only thing that differs is
  whether the first speaker was on the opposition side.
==============================================================*/
DROP TABLE IF EXISTS dbo.pair;
GO

SELECT arm = CASE WHEN a.side = 'opp' THEN 'treatment' ELSE 'control' END,
       a.bill,
       first_id    = a.speech_id,
       first_date  = a.speech_date,
       first_who   = a.speaker_name,
       first_party = a.party,
       later_id    = b.speech_id,
       later_date  = b.speech_date,
       later_who   = b.speaker_name,
       lag_days    = DATEDIFF(day, a.speech_date, b.speech_date),
       distance    = VECTOR_DISTANCE('cosine', av.embedding, bv.embedding)
INTO dbo.pair
FROM dbo.bill_speech a
JOIN dbo.bill_speech b
     ON  b.bill = a.bill
     AND b.role = 'minister'
     AND b.side = 'gov'
     AND DATEDIFF(day, a.speech_date, b.speech_date) BETWEEN 14 AND 400
JOIN dbo.speech_vec av ON av.speech_id = a.speech_id
JOIN dbo.speech_vec bv ON bv.speech_id = b.speech_id
WHERE a.role = 'member'
  AND a.speaker_name <> b.speaker_name;
GO

CREATE INDEX ix_pair ON dbo.pair (arm, lag_days) INCLUDE (distance);
GO

SELECT arm, pairs = COUNT(*), bills = COUNT(DISTINCT bill),
       mean_dist = CAST(AVG(distance) AS DECIMAL(6,4))
FROM dbo.pair GROUP BY arm;
GO

/*==============================================================
  5. THE RESULT

  gap = treatment mean - control mean. Negative means cross-party
  pairs are CLOSER than same-party pairs at that lag, which is
  the shape adoption would make.
==============================================================*/
WITH bucketed AS
(
    SELECT arm, distance,
           bucket = CASE
              WHEN lag_days <  30 THEN '1. 14-30 days'
              WHEN lag_days <  60 THEN '2. 30-60 days'
              WHEN lag_days < 120 THEN '3. 60-120 days'
              WHEN lag_days < 240 THEN '4. 120-240 days'
              ELSE                     '5. 240+ days' END
    FROM dbo.pair
)
SELECT bucket,
       treat_n    = SUM(CASE WHEN arm = 'treatment' THEN 1 ELSE 0 END),
       treat_dist = CAST(AVG(CASE WHEN arm = 'treatment' THEN distance END) AS DECIMAL(6,4)),
       ctrl_n     = SUM(CASE WHEN arm = 'control' THEN 1 ELSE 0 END),
       ctrl_dist  = CAST(AVG(CASE WHEN arm = 'control' THEN distance END) AS DECIMAL(6,4)),
       gap        = CAST(AVG(CASE WHEN arm = 'treatment' THEN distance END)
                       - AVG(CASE WHEN arm = 'control'   THEN distance END) AS DECIMAL(6,4))
FROM bucketed
GROUP BY bucket
ORDER BY bucket;
GO

/*  The tail. Adoption is rare, so a few real cases cannot move a
    mean over millions of pairs - but they should show in the
    closest 1%. This is the more sensitive test.                */
WITH ranked AS
(
    SELECT arm, distance,
           pct = PERCENT_RANK() OVER (PARTITION BY arm ORDER BY distance)
    FROM dbo.pair
)
SELECT arm,
       closest     = CAST(MIN(distance) AS DECIMAL(6,4)),
       p01_mean    = CAST(AVG(CASE WHEN pct <= 0.01 THEN distance END) AS DECIMAL(6,4)),
       p05_mean    = CAST(AVG(CASE WHEN pct <= 0.05 THEN distance END) AS DECIMAL(6,4)),
       overall     = CAST(AVG(distance) AS DECIMAL(6,4))
FROM ranked
GROUP BY arm;
GO

/*==============================================================
  6. The reading list
==============================================================*/
SELECT TOP 30
       p.bill, p.lag_days,
       dist = CAST(p.distance AS DECIMAL(5,3)),
       p.first_date, p.first_who, p.first_party,
       opp_text = LEFT(sa.body, 400),
       p.later_date, p.later_who,
       minister_text = LEFT(sb.body, 400)
FROM dbo.pair p
JOIN dbo.speech sa ON sa.speech_id = p.first_id
JOIN dbo.speech sb ON sb.speech_id = p.later_id
WHERE p.arm = 'treatment'
ORDER BY p.distance;
GO
