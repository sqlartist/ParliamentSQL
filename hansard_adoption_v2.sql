/*==============================================================
  HANSARD - ARGUMENT ADOPTION, v2

  WHY v1 FOUND NOTHING

  The lag distribution came out flat: 0.204, 0.205, 0.205, 0.206,
  0.209 across every lag bucket from a fortnight to a year. If
  adoption were happening there would be a dip around the gap
  between committee and report stage. There was no dip, and 0.205
  turns out to be just the background resemblance of any two
  speeches about the same bill.

  Four defects, all mine:

  1. THE CHAIR WAS IN THE DATA. The top hit at 0.009 was a
     Conservative Deputy Speaker and a Labour Deputy Speaker both
     reading "With this it will be convenient to discuss the
     following amendments..." The Chair is politically neutral in
     the House but the dataset keeps their original party, so
     procedural boilerplate scored as cross-party convergence.

  2. PARTY IS NOT FRONTBENCH. Part B returned almost nothing but
     John McDonnell, a Labour backbencher under a Labour
     government and a famous rebel, counted as "the government"
     because of his party card.

  3. BILL NAMES WERE BROKEN. 'BILL PRESENTED' with 3,225 speeches
     is not a bill. FINANCE BILL and Finance Bill were separate
     bills. Part B matched on a heading of 'Clause 2'.

  4. NO CONTROL. This is the one that actually mattered. 0.205
     means nothing without knowing what SAME-party pairs score at
     the same lag. If they also score 0.205 there is nothing
     here. If they score 0.26, cross-party pairs are genuinely
     closer and the effect was hiding under the noise.

  v2 fixes all four. The null model in Part C is the point; the
  rest is cleanup so the null model is measuring something real.
==============================================================*/

USE HANSARD;
GO
SET NOCOUNT ON;
GO

/*==============================================================
  0. Load the ministerial post columns

  Run hansard_export_posts.py first.
==============================================================*/
DROP TABLE IF EXISTS dbo.speech_post;
GO
CREATE TABLE dbo.speech_post (
    speech_id  INT NOT NULL,
    gov_post   VARCHAR(500) NULL,
    opp_post   VARCHAR(500) NULL,
    parl_post  VARCHAR(500) NULL);
GO

BULK INSERT dbo.speech_post FROM 'C:\SQLData\hansard_load\posts.dat'
  WITH (FIELDTERMINATOR='0x01', ROWTERMINATOR='0x02',
        CODEPAGE='65001', TABLOCK);
GO

ALTER TABLE dbo.speech_post ADD CONSTRAINT pk_speech_post
    PRIMARY KEY CLUSTERED (speech_id);
GO

SELECT rows_loaded  = COUNT(*),
       with_gov_post = SUM(CASE WHEN LEN(gov_post) > 0 THEN 1 ELSE 0 END),
       with_opp_post = SUM(CASE WHEN LEN(opp_post) > 0 THEN 1 ELSE 0 END)
FROM dbo.speech_post;
GO

/*==============================================================
  1. Roles

  Four categories that actually matter, replacing the crude
  government/opposition split by party:

    minister    holds a government post - speaks FOR the government
    shadow      holds an opposition post - speaks FOR the opposition
    backbench   neither, and in a party
    chair       Speaker, Deputy Speaker, Chairman of Ways and Means

  The Chair exclusion is not cosmetic. Those speeches are reading
  out amendment papers verbatim and they dominated v1's rankings.
==============================================================*/
DROP TABLE IF EXISTS dbo.speech_role;
GO

SELECT s.speech_id,
       s.speech_date,
       s.party,
       s.speaker_name,
       s.major_heading,
       role = CASE
           /*  Chair first - it overrides everything, and the test
               is on the NAME because the dataset keeps the
               occupant's original party.                         */
           WHEN s.party = 'Speaker'                              THEN 'chair'
           WHEN s.speaker_name LIKE '%Deputy Speaker%'           THEN 'chair'
           WHEN s.speaker_name LIKE '%Madam Speaker%'            THEN 'chair'
           WHEN s.speaker_name LIKE '%Mr. Speaker%'              THEN 'chair'
           WHEN s.speaker_name LIKE '%Ways and Means%'           THEN 'chair'
           WHEN s.speaker_name LIKE '%Deputy Chairman%'          THEN 'chair'
           WHEN s.speaker_name LIKE '%First Deputy Chairman%'    THEN 'chair'
           WHEN s.speaker_name LIKE 'The Chairman%'              THEN 'chair'
           WHEN LEN(ISNULL(p.gov_post, '')) > 0                  THEN 'minister'
           WHEN LEN(ISNULL(p.opp_post, '')) > 0                  THEN 'shadow'
           ELSE 'backbench' END,
       p.gov_post,
       p.opp_post
INTO dbo.speech_role
FROM dbo.speech s
LEFT JOIN dbo.speech_post p ON p.speech_id = s.speech_id;

CREATE INDEX ix_speech_role ON dbo.speech_role (role, speech_date)
    INCLUDE (speech_id, party);
GO

SELECT role, speeches = COUNT(*)
FROM dbo.speech_role GROUP BY role ORDER BY COUNT(*) DESC;
GO

/*  Sanity: the Chair should be a few tens of thousands and should
    be overwhelmingly procedural. Spot-check that the filter is
    catching the right people and not, say, every MP who once
    said "Deputy Speaker".                                       */
SELECT TOP 20 speaker_name, speeches = COUNT(*)
FROM dbo.speech_role WHERE role = 'chair'
GROUP BY speaker_name ORDER BY COUNT(*) DESC;
GO

/*==============================================================
  2. Bills, properly

  Normalise case and whitespace, strip the Orders of the Day
  prefix and the [Lords] suffix, and throw out the headings that
  are not bills at all.
==============================================================*/
DROP TABLE IF EXISTS dbo.bill_speech;
GO

WITH stripped AS
(
    SELECT r.speech_id, r.speech_date, r.party, r.speaker_name, r.role,
           raw = LTRIM(RTRIM(
                   REPLACE(REPLACE(REPLACE(REPLACE(
                     CASE WHEN CHARINDEX(N'—', r.major_heading) > 0
                          THEN SUBSTRING(r.major_heading,
                                 CHARINDEX(N'—', r.major_heading) + 1, 500)
                          ELSE r.major_heading END,
                   '[Lords]', ''), '[ Lords ]', ''),
                   'Orders of the Day', ''), '(By Order)', '')))
    FROM dbo.speech_role r
    WHERE r.major_heading LIKE '%Bill%'
)
SELECT speech_id, speech_date, party, speaker_name, role,
       /*  UPPER collapses FINANCE BILL and Finance Bill, which
           v1 treated as two different bills.                    */
       bill = UPPER(LTRIM(RTRIM(REPLACE(REPLACE(raw, '  ', ' '), '  ', ' '))))
INTO dbo.bill_speech
FROM stripped
WHERE LEN(raw) > 6
  /*  Not bills. 'BILL PRESENTED' alone was 3,225 speeches in v1
      and is just the formal first-reading announcement.         */
  AND UPPER(raw) NOT LIKE 'BILL%PRESENTED%'
  AND UPPER(raw) NOT LIKE 'BILLS%PRESENTED%'
  AND UPPER(raw) NOT LIKE 'CLAUSE %'
  AND UPPER(raw) NOT LIKE 'NEW CLAUSE%'
  AND UPPER(raw) NOT LIKE 'SCHEDULE %'
  AND UPPER(raw) NOT LIKE '%PRIVATE BUSINESS%';

CREATE INDEX ix_bill_speech ON dbo.bill_speech (bill, speech_date)
    INCLUDE (speech_id, role, party);
GO

SELECT bills = COUNT(DISTINCT bill), speeches = COUNT(*)
FROM dbo.bill_speech;

SELECT TOP 20 bill, speeches = COUNT(*),
       sitting_days = COUNT(DISTINCT speech_date),
       ministers = SUM(CASE WHEN role = 'minister' THEN 1 ELSE 0 END),
       shadows   = SUM(CASE WHEN role = 'shadow'   THEN 1 ELSE 0 END)
FROM dbo.bill_speech
GROUP BY bill
HAVING COUNT(DISTINCT speech_date) > 1
ORDER BY COUNT(*) DESC;
GO

/*==============================================================
  3. The pair set - treatment AND control together

  This is the part v1 got wrong by omission. Every pair is built
  the same way: same bill, 14 to 400 days apart, second speaker
  is a minister. The only thing that varies is whether the FIRST
  speaker was on the other side.

    treatment   shadow -> minister    (possible adoption)
    control     minister -> minister  (same side, same bill)

  If adoption is real, treatment distances should be lower than
  control at the lags where adoption happens. If the two curves
  sit on top of each other, there is nothing here and the honest
  answer is to say so.

  No Chair on either side.
==============================================================*/
DROP TABLE IF EXISTS dbo.pair;
GO

SELECT arm = CASE WHEN a.role = 'shadow' THEN 'treatment' ELSE 'control' END,
       a.bill,
       first_id    = a.speech_id,
       first_date  = a.speech_date,
       first_who   = a.speaker_name,
       first_party = a.party,
       first_role  = a.role,
       later_id    = b.speech_id,
       later_date  = b.speech_date,
       later_who   = b.speaker_name,
       later_party = b.party,
       lag_days    = DATEDIFF(day, a.speech_date, b.speech_date),
       distance    = VECTOR_DISTANCE('cosine', av.embedding, bv.embedding)
INTO dbo.pair
FROM dbo.bill_speech a
JOIN dbo.bill_speech b
     ON  b.bill = a.bill
     AND b.role = 'minister'
     AND DATEDIFF(day, a.speech_date, b.speech_date) BETWEEN 14 AND 400
JOIN dbo.speech_vec av ON av.speech_id = a.speech_id
JOIN dbo.speech_vec bv ON bv.speech_id = b.speech_id
WHERE a.role IN ('shadow', 'minister')
  /*  Different people. A minister echoing himself six weeks
      later is not adoption, it is a brief.                      */
  AND a.speaker_name <> b.speaker_name
  /*  Cross-party for treatment, same-party for control.         */
  AND ((a.role = 'shadow'   AND a.party <> b.party)
    OR (a.role = 'minister' AND a.party =  b.party));
GO

CREATE INDEX ix_pair ON dbo.pair (arm, lag_days) INCLUDE (distance);
GO

SELECT arm, pairs = COUNT(*), bills = COUNT(DISTINCT bill),
       mean_dist = CAST(AVG(distance) AS DECIMAL(6,4))
FROM dbo.pair GROUP BY arm;
GO

/*==============================================================
  4. THE RESULT

  Treatment against control, bucketed by lag. The gap column is
  the whole analysis.
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
       treatment_n    = SUM(CASE WHEN arm = 'treatment' THEN 1 ELSE 0 END),
       treatment_dist = CAST(AVG(CASE WHEN arm = 'treatment'
                                      THEN distance END) AS DECIMAL(6,4)),
       control_n      = SUM(CASE WHEN arm = 'control' THEN 1 ELSE 0 END),
       control_dist   = CAST(AVG(CASE WHEN arm = 'control'
                                      THEN distance END) AS DECIMAL(6,4)),
       /*  Negative = cross-party pairs are CLOSER than same-party
           pairs at this lag. That would be the finding.          */
       gap            = CAST(AVG(CASE WHEN arm = 'treatment' THEN distance END)
                           - AVG(CASE WHEN arm = 'control'   THEN distance END)
                             AS DECIMAL(6,4))
FROM bucketed
GROUP BY bucket
ORDER BY bucket;
GO

/*  Same thing at the tail of the distribution rather than the
    mean. Adoption, if it exists, is rare - a handful of genuine
    cases will not move an average over hundreds of thousands of
    pairs, but they should show up in the closest 1%.           */
WITH ranked AS
(
    SELECT arm, distance,
           pct = PERCENT_RANK() OVER (PARTITION BY arm ORDER BY distance)
    FROM dbo.pair
)
SELECT arm,
       p01 = CAST(MIN(CASE WHEN pct <= 0.01 THEN distance END) AS DECIMAL(6,4)),
       p01_mean = CAST(AVG(CASE WHEN pct <= 0.01 THEN distance END) AS DECIMAL(6,4)),
       p05_mean = CAST(AVG(CASE WHEN pct <= 0.05 THEN distance END) AS DECIMAL(6,4)),
       median   = CAST(AVG(CASE WHEN pct BETWEEN 0.49 AND 0.51
                                THEN distance END) AS DECIMAL(6,4))
FROM ranked
GROUP BY arm;
GO

/*==============================================================
  5. The reading list

  Closest treatment pairs, with their control-arm context. These
  are candidates for a human to judge, not findings.
==============================================================*/
SELECT TOP 30
       p.bill, p.lag_days,
       dist = CAST(p.distance AS DECIMAL(5,3)),
       p.first_date, p.first_who, p.first_party,
       shadow_text = LEFT(sa.body, 400),
       p.later_date, p.later_who, p.later_party,
       minister_text = LEFT(sb.body, 400)
FROM dbo.pair p
JOIN dbo.speech sa ON sa.speech_id = p.first_id
JOIN dbo.speech sb ON sb.speech_id = p.later_id
WHERE p.arm = 'treatment'
ORDER BY p.distance;
GO

/*==============================================================
  WHAT A RESULT LOOKS LIKE

  gap near zero in every bucket
      No adoption signal. Cross-party pairs resemble each other
      exactly as much as same-party pairs do, which is to say
      they are all just speeches about the same bill. Report it
      as a null result - it is still a result, and it is the one
      I would bet on.

  gap negative and largest in buckets 2-3
      Cross-party pairs converge more than same-party pairs at
      the committee-to-report gap. That is the shape adoption
      would make, and it is worth the second article.

  gap negative everywhere, flat
      Something structural, not adoption. Most likely ministers
      replying directly to shadows and quoting them to disagree.
      Check the reading list for rejection language.

  Remaining caveats, unfixed:

    - Ministers quoting an amendment to reject it scores as
      maximum similarity and is the opposite of adoption. No
      filter for this yet; it needs a sentiment or stance model.
    - Both sides reading the same select committee report
      converge on a source, not on each other.
    - Post data is held per speech, so an MP promoted mid-bill
      changes role partway through. That is correct behaviour
      but worth knowing.
==============================================================*/
