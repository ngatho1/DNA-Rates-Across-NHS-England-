-- =============================================================
-- PROJECT: The GP Appointment Squeeze
-- Tool:    SQLite — use DB Browser: https://sqlitebrowser.org/
-- Author:  David Kamande
-- Version: 3 — schema updated to match actual CSV structures
-- =============================================================
-- DATASET OVERVIEW
--   national_overview_raw   → National_Overview.csv
--                             49,703 rows | 8 cols | 30 months
--                             Used for: Q2 national trend analysis
--
--   pcn_granular_raw        → PCN_GRANULAR.csv
--                             154,002 rows | 13 cols | 21 months
--                             Used for: Q1 regional DNA rates
--                                        Q3 deprivation inequality
--
--   deprivation_raw         → IMD 2019 File 7 CSV (gov.uk)
--                             Used for: Q3 deprivation join
--
--   NOTE: The ODS organisations table has been removed.
--   Geography (Sub-ICB, ICB, Region) is already embedded
--   in PCN_GRANULAR.csv — no reference table needed.
-- =============================================================
-- STEP OVERVIEW
--   STEP 1  → Raw table schemas
--   STEP 2  → Sense checks on raw data
--   STEP 3  → Data cleaning → creates _clean tables
--   STEP 4  → Post-cleaning sense checks
--   STEP 5  → Analysis Q1: Where are DNA rates highest?
--   STEP 6  → Analysis Q2: How has appointment mode shifted?
--   STEP 7  → Analysis Q3: Is there an inequality pattern?
--   STEP 8  → Export queries for Excel
-- =============================================================


-- =============================================================
-- STEP 1: RAW TABLE SCHEMAS
-- Import your CSVs into these tables first using:
-- File > Import > Table from CSV in DB Browser
-- Name each table exactly as shown below.
-- Numeric columns are imported as TEXT intentionally —
-- this catches non-numeric values before casting.
-- =============================================================

-- TABLE 1: National Overview (raw)
-- Source: National_Overview.csv
-- Contains: national-level counts by status, mode, HCP type
-- No geography — aggregated across all of England
CREATE TABLE IF NOT EXISTS national_overview_raw (
    APPOINTMENT_MONTH   TEXT,   -- format: 'APR2023'
    APPT_STATUS         TEXT,   -- 'Attended', 'DNA', 'Unknown'
    HCP_TYPE            TEXT,   -- 'GP', 'Other Practice staff', 'Unknown'
    APPT_MODE           TEXT,   -- 'Face-to-Face', 'Telephone', etc.
    SERVICE_SETTING     TEXT,
    CONTEXT_TYPE        TEXT,
    NATIONAL_CATEGORY   TEXT,
    APPOINTMENTS        TEXT    -- imported as TEXT; cast to INTEGER in Step 3
);

-- TABLE 2: PCN Granular (raw)
-- Source: PCN_GRANULAR.csv
-- Contains: Sub-ICB level counts by status, mode, HCP type
-- Geography fully embedded — no ODS reference table needed
CREATE TABLE IF NOT EXISTS pcn_granular_raw (
    SUB_ICB_LOCATION_CODE       TEXT,
    SUB_ICB_LOCATION_ONS_CODE   TEXT,
    SUB_ICB_LOCATION_NAME       TEXT,
    ICB_ONS_CODE                TEXT,
    ICB_NAME                    TEXT,
    REGION_ONS_CODE             TEXT,
    REGION_NAME                 TEXT,
    APPOINTMENT_MONTH           TEXT,   -- format: '01APR2023'
    APPT_STATUS                 TEXT,   -- 'Attended', 'DNA', 'Booked', 'Unknown'
    HCP_TYPE                    TEXT,
    APPT_MODE                   TEXT,
    TIME_BETWEEN_BOOK_AND_APPT  TEXT,
    COUNT_OF_APPOINTMENTS       TEXT    -- imported as TEXT; cast to INTEGER in Step 3
);

-- TABLE 3: Index of Multiple Deprivation 2019 (raw)
-- Source: File 7 — English Indices of Deprivation 2019 (gov.uk)
-- Contains: IMD scores, ranks, deciles at LSOA level
CREATE TABLE IF NOT EXISTS deprivation_raw (
    LSOA_CODE           TEXT,
    LSOA_NAME           TEXT,
    LA_DISTRICT_CODE    TEXT,
    LA_DISTRICT_NAME    TEXT,
    IMD_SCORE           TEXT,
    IMD_RANK            TEXT,
    IMD_DECILE          TEXT,
    INCOME_SCORE        TEXT,
    EMPLOYMENT_SCORE    TEXT,
    EDUCATION_SCORE     TEXT,
    HEALTH_SCORE        TEXT,
    CRIME_SCORE         TEXT,
    HOUSING_SCORE       TEXT,
    ENVIRONMENT_SCORE   TEXT
);


-- =============================================================
-- STEP 2: SENSE CHECKS ON RAW DATA
-- Run immediately after each CSV import.
-- These are diagnostic — they identify what needs fixing
-- in Step 3 before any analysis is run.
-- =============================================================

-- 2a. Row counts — confirm all files loaded fully
--     Expected: national_overview ~49,703 | pcn_granular ~154,002
SELECT 'national_overview_raw' AS table_name, COUNT(*) AS row_count
FROM national_overview_raw
UNION ALL
SELECT 'pcn_granular_raw',      COUNT(*) FROM pcn_granular_raw
UNION ALL
SELECT 'deprivation_raw',       COUNT(*) FROM deprivation_raw;

-- 2b. Date range — national overview
--     Expected: 30 distinct months (Jul 2022 – Dec 2024)
SELECT
    MIN(APPOINTMENT_MONTH)              AS earliest,
    MAX(APPOINTMENT_MONTH)              AS latest,
    COUNT(DISTINCT APPOINTMENT_MONTH)   AS distinct_months
FROM national_overview_raw;

-- 2c. Date range — PCN granular
--     Expected: 21 distinct months (Apr 2023 – Dec 2024)
SELECT
    MIN(APPOINTMENT_MONTH)              AS earliest,
    MAX(APPOINTMENT_MONTH)              AS latest,
    COUNT(DISTINCT APPOINTMENT_MONTH)   AS distinct_months
FROM pcn_granular_raw;

-- 2d. APPT_STATUS values — national overview
--     Expected: 'Attended', 'DNA', 'Unknown'
SELECT APPT_STATUS, COUNT(*) AS row_count
FROM national_overview_raw
GROUP BY APPT_STATUS;

-- 2e. APPT_STATUS values — PCN granular
--     Expected: 'Attended', 'DNA', 'Booked', 'Unknown'
--     NOTE: 'Booked' = future appointments with no outcome yet
--     These must be excluded from all DNA rate calculations
SELECT APPT_STATUS, COUNT(*) AS row_count
FROM pcn_granular_raw
GROUP BY APPT_STATUS;

-- 2f. Duplicate rows — PCN granular
SELECT
    SUB_ICB_LOCATION_CODE, APPOINTMENT_MONTH, APPT_STATUS,
    APPT_MODE, HCP_TYPE, TIME_BETWEEN_BOOK_AND_APPT,
    COUNT(*) AS occurrences
FROM pcn_granular_raw
GROUP BY
    SUB_ICB_LOCATION_CODE, APPOINTMENT_MONTH, APPT_STATUS,
    APPT_MODE, HCP_TYPE, TIME_BETWEEN_BOOK_AND_APPT
HAVING COUNT(*) > 1
LIMIT 10;

-- 2g. REGION_NAME values — check for UNMAPPED rows
--     Expected: 7 NHS regions + 'UNMAPPED'
--     UNMAPPED rows have no geographic identity and must be excluded
SELECT REGION_NAME, COUNT(*) AS row_count
FROM pcn_granular_raw
GROUP BY REGION_NAME
ORDER BY row_count DESC;

-- 2h. COUNT_OF_APPOINTMENTS quality — PCN granular
--     Expected: all integers >= 1, no nulls or blanks
SELECT
    SUM(CASE WHEN COUNT_OF_APPOINTMENTS IS NULL
             OR TRIM(COUNT_OF_APPOINTMENTS) = ''
             THEN 1 ELSE 0 END)     AS null_or_blank,
    MIN(CAST(COUNT_OF_APPOINTMENTS AS INTEGER)) AS min_value,
    MAX(CAST(COUNT_OF_APPOINTMENTS AS INTEGER)) AS max_value
FROM pcn_granular_raw;

-- 2i. APPOINTMENTS quality — national overview
SELECT
    SUM(CASE WHEN APPOINTMENTS IS NULL
             OR TRIM(APPOINTMENTS) = ''
             THEN 1 ELSE 0 END)     AS null_or_blank,
    MIN(CAST(APPOINTMENTS AS INTEGER)) AS min_value,
    MAX(CAST(APPOINTMENTS AS INTEGER)) AS max_value
FROM national_overview_raw;

-- 2j. Duplicate rows — PCN granular
SELECT
    SUB_ICB_LOCATION_CODE, APPOINTMENT_MONTH, APPT_STATUS,
    APPT_MODE, HCP_TYPE, TIME_BETWEEN_BOOK_AND_APPT,
    COUNT(*) AS occurrences
FROM pcn_granular_raw
GROUP BY
    SUB_ICB_LOCATION_CODE, APPOINTMENT_MONTH, APPT_STATUS,
    APPT_MODE, HCP_TYPE, TIME_BETWEEN_BOOK_AND_APPT
HAVING COUNT(*) > 1
LIMIT 10;

-- 2k. Deprivation — missing values and decile range
--     Column names use double quotes — required for names
--     containing spaces and brackets
SELECT
    COUNT(*)                                                        AS total_rows,
    SUM(CASE WHEN TRIM(COALESCE("LSOA code (2011)",'')) = ''
             THEN 1 ELSE 0 END)                                     AS missing_lsoa,
    SUM(CASE WHEN "Index of Multiple Deprivation (IMD) Decile (where 1 is most deprived 10% of LSOAs)"
             IS NULL
             THEN 1 ELSE 0 END)                                     AS missing_decile,
    MIN("Index of Multiple Deprivation (IMD) Decile (where 1 is most deprived 10% of LSOAs)")
                                                                    AS min_decile,
    MAX("Index of Multiple Deprivation (IMD) Decile (where 1 is most deprived 10% of LSOAs)")
                                                                    AS max_decile
FROM deprivation_raw;


-- =============================================================
-- STEP 3: DATA CLEANING
-- Creates three cleaned tables from the raw imports.
-- Every fix is commented — this forms your methodology notes.
-- Run once. All analysis in Steps 5–8 uses _clean tables only.
-- =============================================================

-- -----------------------------------------------------------
-- 3a. CLEAN: national_overview
-- -----------------------------------------------------------
-- Fixes applied:
--   (i)   APPOINTMENT_MONTH converted from 'APR2023' to
--          'YYYY-MM-DD' format for correct chronological sorting.
--          SQLite has no native month parser for this format,
--          so a CASE statement maps each month abbreviation.
--   (ii)  APPT_STATUS normalised: 'DNA' → 'Did Not Attend'
--          to match standard NHS terminology used in the project
--   (iii) APPT_MODE renamed to APPOINTMENT_MODE for consistency
--          with PCN granular table in join/union scenarios
--   (iv)  APPOINTMENTS cast from TEXT to INTEGER
--   (v)   TRIM() on all text fields removes invisible whitespace
--   (vi)  Zero-count rows excluded (none expected but defensive)

CREATE TABLE IF NOT EXISTS national_overview_clean AS
SELECT
    -- (i) Convert 'APR2023' → 'YYYY-MM-01'
    CASE SUBSTR(TRIM(APPOINTMENT_MONTH), 1, 3)
        WHEN 'JAN' THEN SUBSTR(TRIM(APPOINTMENT_MONTH),4,4)||'-01-01'
        WHEN 'FEB' THEN SUBSTR(TRIM(APPOINTMENT_MONTH),4,4)||'-02-01'
        WHEN 'MAR' THEN SUBSTR(TRIM(APPOINTMENT_MONTH),4,4)||'-03-01'
        WHEN 'APR' THEN SUBSTR(TRIM(APPOINTMENT_MONTH),4,4)||'-04-01'
        WHEN 'MAY' THEN SUBSTR(TRIM(APPOINTMENT_MONTH),4,4)||'-05-01'
        WHEN 'JUN' THEN SUBSTR(TRIM(APPOINTMENT_MONTH),4,4)||'-06-01'
        WHEN 'JUL' THEN SUBSTR(TRIM(APPOINTMENT_MONTH),4,4)||'-07-01'
        WHEN 'AUG' THEN SUBSTR(TRIM(APPOINTMENT_MONTH),4,4)||'-08-01'
        WHEN 'SEP' THEN SUBSTR(TRIM(APPOINTMENT_MONTH),4,4)||'-09-01'
        WHEN 'OCT' THEN SUBSTR(TRIM(APPOINTMENT_MONTH),4,4)||'-10-01'
        WHEN 'NOV' THEN SUBSTR(TRIM(APPOINTMENT_MONTH),4,4)||'-11-01'
        WHEN 'DEC' THEN SUBSTR(TRIM(APPOINTMENT_MONTH),4,4)||'-12-01'
        ELSE TRIM(APPOINTMENT_MONTH)
    END                                                     AS APPOINTMENT_MONTH,

    -- (ii) Normalise status terminology
    CASE TRIM(UPPER(APPT_STATUS))
        WHEN 'ATTENDED'     THEN 'Attended'
        WHEN 'DNA'          THEN 'Did Not Attend'
        WHEN 'UNKNOWN'      THEN 'Unknown'
        ELSE                     'Unknown'
    END                                                     AS APPOINTMENT_STATUS,

    -- (v) Trim all text fields
    TRIM(HCP_TYPE)                                          AS HCP_TYPE,

    -- (iii) Rename for consistency
    CASE TRIM(UPPER(APPT_MODE))
        WHEN 'FACE-TO-FACE'             THEN 'Face-to-Face'
        WHEN 'TELEPHONE'                THEN 'Telephone'
        WHEN 'HOME VISIT'               THEN 'Home Visit'
        WHEN 'VIDEO CONFERENCE/ONLINE'  THEN 'Video/Online'
        WHEN 'UNKNOWN'                  THEN 'Unknown'
        ELSE                                 'Unknown'
    END                                                     AS APPOINTMENT_MODE,

    TRIM(SERVICE_SETTING)                                   AS SERVICE_SETTING,
    TRIM(CONTEXT_TYPE)                                      AS CONTEXT_TYPE,
    TRIM(NATIONAL_CATEGORY)                                 AS NATIONAL_CATEGORY,

    -- (iv) Cast to integer
    COALESCE(CAST(NULLIF(TRIM(APPOINTMENTS),'') AS INTEGER), 0)
                                                            AS APPOINTMENTS

FROM national_overview_raw

-- (vi) Exclude zero-count rows
WHERE COALESCE(CAST(NULLIF(TRIM(APPOINTMENTS),'') AS INTEGER), 0) > 0;


-- -----------------------------------------------------------
-- 3b. CLEAN: pcn_granular
-- -----------------------------------------------------------
-- Fixes applied:
--   (i)   APPOINTMENT_MONTH converted from '01APR2023' to
--          'YYYY-MM-DD'. This format has a leading '01' day
--          prefix before the month abbreviation, so parsing
--          starts at position 3 rather than 1.
--   (ii)  APPT_STATUS normalised: 'DNA' → 'Did Not Attend'
--   (iii) 'Booked' rows excluded — these are future appointments
--          with no attendance outcome. Including them in DNA
--          rate denominators would understate the true rate.
--          Documented here for methodology notes.
--   (iv)  UNMAPPED rows excluded — SUB_ICB_LOCATION_CODE =
--          'UNMAPPED' carries no geographic identity and cannot
--          contribute to regional or deprivation analysis.
--   (v)   APPT_MODE normalised and renamed to APPOINTMENT_MODE
--   (vi)  COUNT_OF_APPOINTMENTS cast to INTEGER
--   (vii) TRIM() on all text fields
--   (viii) Zero-count rows excluded (defensive — none expected)

CREATE TABLE IF NOT EXISTS pcn_granular_clean AS
SELECT
    TRIM(UPPER(SUB_ICB_LOCATION_CODE))                      AS SUB_ICB_LOCATION_CODE,
    TRIM(SUB_ICB_LOCATION_ONS_CODE)                         AS SUB_ICB_LOCATION_ONS_CODE,
    TRIM(SUB_ICB_LOCATION_NAME)                             AS SUB_ICB_LOCATION_NAME,
    TRIM(ICB_ONS_CODE)                                      AS ICB_ONS_CODE,
    TRIM(ICB_NAME)                                          AS ICB_NAME,
    TRIM(REGION_ONS_CODE)                                   AS REGION_ONS_CODE,
    TRIM(REGION_NAME)                                       AS REGION_NAME,

    -- (i) Convert '01APR2023' → 'YYYY-MM-01'
    --     Day prefix '01' occupies positions 1-2, month at 3-5, year at 6-9
    CASE SUBSTR(TRIM(APPOINTMENT_MONTH), 3, 3)
        WHEN 'JAN' THEN SUBSTR(TRIM(APPOINTMENT_MONTH),6,4)||'-01-01'
        WHEN 'FEB' THEN SUBSTR(TRIM(APPOINTMENT_MONTH),6,4)||'-02-01'
        WHEN 'MAR' THEN SUBSTR(TRIM(APPOINTMENT_MONTH),6,4)||'-03-01'
        WHEN 'APR' THEN SUBSTR(TRIM(APPOINTMENT_MONTH),6,4)||'-04-01'
        WHEN 'MAY' THEN SUBSTR(TRIM(APPOINTMENT_MONTH),6,4)||'-05-01'
        WHEN 'JUN' THEN SUBSTR(TRIM(APPOINTMENT_MONTH),6,4)||'-06-01'
        WHEN 'JUL' THEN SUBSTR(TRIM(APPOINTMENT_MONTH),6,4)||'-07-01'
        WHEN 'AUG' THEN SUBSTR(TRIM(APPOINTMENT_MONTH),6,4)||'-08-01'
        WHEN 'SEP' THEN SUBSTR(TRIM(APPOINTMENT_MONTH),6,4)||'-09-01'
        WHEN 'OCT' THEN SUBSTR(TRIM(APPOINTMENT_MONTH),6,4)||'-10-01'
        WHEN 'NOV' THEN SUBSTR(TRIM(APPOINTMENT_MONTH),6,4)||'-11-01'
        WHEN 'DEC' THEN SUBSTR(TRIM(APPOINTMENT_MONTH),6,4)||'-12-01'
        ELSE TRIM(APPOINTMENT_MONTH)
    END                                                     AS APPOINTMENT_MONTH,

    -- (ii) Normalise status; (iii) 'Booked' handled via WHERE clause below
    CASE TRIM(UPPER(APPT_STATUS))
        WHEN 'ATTENDED'     THEN 'Attended'
        WHEN 'DNA'          THEN 'Did Not Attend'
        WHEN 'UNKNOWN'      THEN 'Unknown'
        ELSE                     'Unknown'
    END                                                     AS APPOINTMENT_STATUS,

    TRIM(HCP_TYPE)                                          AS HCP_TYPE,

    -- (v) Normalise and rename mode
    CASE TRIM(UPPER(APPT_MODE))
        WHEN 'FACE-TO-FACE'             THEN 'Face-to-Face'
        WHEN 'TELEPHONE'                THEN 'Telephone'
        WHEN 'HOME VISIT'               THEN 'Home Visit'
        WHEN 'VIDEO CONFERENCE/ONLINE'  THEN 'Video/Online'
        WHEN 'UNKNOWN'                  THEN 'Unknown'
        ELSE                                 'Unknown'
    END                                                     AS APPOINTMENT_MODE,

    TRIM(TIME_BETWEEN_BOOK_AND_APPT)                        AS TIME_BETWEEN_BOOK_AND_APPT,

    -- (vi) Cast to integer
    COALESCE(CAST(NULLIF(TRIM(COUNT_OF_APPOINTMENTS),'') AS INTEGER), 0)
                                                            AS COUNT_OF_APPOINTMENTS

FROM pcn_granular_raw

WHERE
    -- (iii) Exclude 'Booked' — future appointments, no outcome yet
    TRIM(UPPER(APPT_STATUS)) != 'BOOKED'
    -- (iv) Exclude UNMAPPED — no geographic identity
    AND TRIM(UPPER(SUB_ICB_LOCATION_CODE)) != 'UNMAPPED'
    -- (viii) Exclude zero-count rows
    AND COALESCE(CAST(NULLIF(TRIM(COUNT_OF_APPOINTMENTS),'') AS INTEGER), 0) > 0;


-- -----------------------------------------------------------
-- 3c. CLEAN: deprivation
-- -----------------------------------------------------------
-- Fixes applied:
--   (i)   All score/rank/decile columns cast from TEXT to REAL/INTEGER
--   (ii)  Rows with missing LSOA_CODE excluded
--   (iii) IMD_DECILE validated: must be 1–10
--          Out-of-range values indicate a data entry error;
--          set to NULL to preserve the row for score-based joins
--   (iv)  Codes uppercased and trimmed for reliable joining

CREATE TABLE IF NOT EXISTS deprivation_clean AS
SELECT
    TRIM(UPPER(LSOA_CODE))                                  AS LSOA_CODE,
    TRIM(LSOA_NAME)                                         AS LSOA_NAME,
    TRIM(UPPER(LA_DISTRICT_CODE))                           AS LA_DISTRICT_CODE,
    TRIM(LA_DISTRICT_NAME)                                  AS LA_DISTRICT_NAME,
    CAST(NULLIF(TRIM(IMD_SCORE),'')         AS REAL)        AS IMD_SCORE,
    CAST(NULLIF(TRIM(IMD_RANK),'')          AS INTEGER)     AS IMD_RANK,
    -- (iii) Validate decile is within 1–10
    CASE
        WHEN CAST(NULLIF(TRIM(IMD_DECILE),'') AS INTEGER) BETWEEN 1 AND 10
            THEN CAST(NULLIF(TRIM(IMD_DECILE),'') AS INTEGER)
        ELSE NULL
    END                                                     AS IMD_DECILE,
    CAST(NULLIF(TRIM(INCOME_SCORE),'')      AS REAL)        AS INCOME_SCORE,
    CAST(NULLIF(TRIM(EMPLOYMENT_SCORE),'')  AS REAL)        AS EMPLOYMENT_SCORE,
    CAST(NULLIF(TRIM(EDUCATION_SCORE),'')   AS REAL)        AS EDUCATION_SCORE,
    CAST(NULLIF(TRIM(HEALTH_SCORE),'')      AS REAL)        AS HEALTH_SCORE,
    CAST(NULLIF(TRIM(CRIME_SCORE),'')       AS REAL)        AS CRIME_SCORE,
    CAST(NULLIF(TRIM(HOUSING_SCORE),'')     AS REAL)        AS HOUSING_SCORE,
    CAST(NULLIF(TRIM(ENVIRONMENT_SCORE),'') AS REAL)        AS ENVIRONMENT_SCORE
FROM deprivation_raw
-- (ii) Only keep rows with a valid LSOA code
WHERE TRIM(COALESCE(LSOA_CODE,'')) != '';


-- =============================================================
-- STEP 4: POST-CLEANING SENSE CHECKS
-- Confirm every issue from Step 2 has been resolved.
-- Also produces the cleaning audit log for your write-up.
-- =============================================================

-- 4a. Raw vs clean row counts
SELECT 'national_overview' AS dataset,
    (SELECT COUNT(*) FROM national_overview_raw)    AS raw_rows,
    (SELECT COUNT(*) FROM national_overview_clean)  AS clean_rows,
    (SELECT COUNT(*) FROM national_overview_raw)
    - (SELECT COUNT(*) FROM national_overview_clean) AS rows_removed
UNION ALL
SELECT 'pcn_granular',
    (SELECT COUNT(*) FROM pcn_granular_raw),
    (SELECT COUNT(*) FROM pcn_granular_clean),
    (SELECT COUNT(*) FROM pcn_granular_raw)
    - (SELECT COUNT(*) FROM pcn_granular_clean)
UNION ALL
SELECT 'deprivation',
    (SELECT COUNT(*) FROM deprivation_raw),
    (SELECT COUNT(*) FROM deprivation_clean),
    (SELECT COUNT(*) FROM deprivation_raw)
    - (SELECT COUNT(*) FROM deprivation_clean);

-- 4b. Confirm APPOINTMENT_STATUS — national overview
--     Should only show: Attended | Did Not Attend | Unknown
SELECT APPOINTMENT_STATUS, COUNT(*) AS row_count
FROM national_overview_clean
GROUP BY APPOINTMENT_STATUS;

-- 4c. Confirm APPOINTMENT_STATUS — PCN granular
--     'Booked' must NOT appear here
SELECT APPOINTMENT_STATUS, COUNT(*) AS row_count
FROM pcn_granular_clean
GROUP BY APPOINTMENT_STATUS;

-- 4d. Confirm UNMAPPED rows removed from PCN granular
SELECT COUNT(*) AS unmapped_rows_remaining
FROM pcn_granular_clean
WHERE SUB_ICB_LOCATION_CODE = 'UNMAPPED';

-- 4e. Confirm APPOINTMENT_MODE values — PCN granular
SELECT APPOINTMENT_MODE, COUNT(*) AS row_count
FROM pcn_granular_clean
GROUP BY APPOINTMENT_MODE;

-- 4f. Confirm date conversion worked — both tables
--     Dates should now sort chronologically as text
SELECT 'national_overview' AS source,
    MIN(APPOINTMENT_MONTH) AS earliest,
    MAX(APPOINTMENT_MONTH) AS latest,
    COUNT(DISTINCT APPOINTMENT_MONTH) AS distinct_months
FROM national_overview_clean
UNION ALL
SELECT 'pcn_granular',
    MIN(APPOINTMENT_MONTH),
    MAX(APPOINTMENT_MONTH),
    COUNT(DISTINCT APPOINTMENT_MONTH)
FROM pcn_granular_clean;

-- 4g. Confirm COUNT_OF_APPOINTMENTS — no nulls or zeros remain
SELECT
    SUM(CASE WHEN COUNT_OF_APPOINTMENTS IS NULL THEN 1 ELSE 0 END) AS nulls,
    SUM(CASE WHEN COUNT_OF_APPOINTMENTS = 0     THEN 1 ELSE 0 END) AS zeros,
    MIN(COUNT_OF_APPOINTMENTS)                                      AS min_val,
    MAX(COUNT_OF_APPOINTMENTS)                                      AS max_val
FROM pcn_granular_clean;

-- 4h. Confirm IMD decile range is 1–10 only
SELECT IMD_DECILE, COUNT(*) AS lsoa_count
FROM deprivation_clean
GROUP BY IMD_DECILE
ORDER BY IMD_DECILE;

-- 4i. Cleaning audit log — paste into methodology section
SELECT 'National Overview: zero-count rows removed'         AS cleaning_action,
    (SELECT COUNT(*) FROM national_overview_raw)
    - (SELECT COUNT(*) FROM national_overview_clean)        AS records_affected
UNION ALL
SELECT 'PCN Granular: Booked rows excluded (no outcome yet)',
    (SELECT COUNT(*) FROM pcn_granular_raw
     WHERE TRIM(UPPER(APPT_STATUS)) = 'BOOKED')
UNION ALL
SELECT 'PCN Granular: UNMAPPED region rows excluded',
    (SELECT COUNT(*) FROM pcn_granular_raw
     WHERE TRIM(UPPER(SUB_ICB_LOCATION_CODE)) = 'UNMAPPED')
UNION ALL
SELECT 'PCN Granular: zero-count rows excluded (defensive)',
    (SELECT COUNT(*) FROM pcn_granular_raw
     WHERE COALESCE(CAST(NULLIF(TRIM(COUNT_OF_APPOINTMENTS),'')
           AS INTEGER),0) = 0)
UNION ALL
SELECT 'Deprivation: rows without LSOA code excluded',
    (SELECT COUNT(*) FROM deprivation_raw)
    - (SELECT COUNT(*) FROM deprivation_clean);


-- =============================================================
-- STEP 5: ANALYSIS — Q1: WHERE ARE DNA RATES HIGHEST?
-- Source: pcn_granular_clean
-- 'Unknown' status excluded from all DNA rate denominators.
-- This is consistent throughout Steps 5–7 and documented in 4i.
-- =============================================================

-- 5a. National DNA rate baseline from PCN data
--     Use this as the benchmark figure in your write-up
SELECT
    APPOINTMENT_STATUS,
    SUM(COUNT_OF_APPOINTMENTS)                              AS total_appointments,
    ROUND(
        100.0 * SUM(COUNT_OF_APPOINTMENTS)
        / SUM(SUM(COUNT_OF_APPOINTMENTS)) OVER (), 2
    )                                                       AS pct_of_total
FROM pcn_granular_clean
WHERE APPOINTMENT_STATUS IN ('Attended', 'Did Not Attend')
GROUP BY APPOINTMENT_STATUS;

-- 5b. DNA rate by Region — high-level story (7 regions)
SELECT
    REGION_NAME,
    SUM(CASE WHEN APPOINTMENT_STATUS = 'Did Not Attend'
             THEN COUNT_OF_APPOINTMENTS ELSE 0 END)         AS dna_count,
    SUM(CASE WHEN APPOINTMENT_STATUS IN ('Attended','Did Not Attend')
             THEN COUNT_OF_APPOINTMENTS ELSE 0 END)         AS total_appointments,
    ROUND(
        100.0
        * SUM(CASE WHEN APPOINTMENT_STATUS = 'Did Not Attend'
                   THEN COUNT_OF_APPOINTMENTS ELSE 0 END)
        / NULLIF(
            SUM(CASE WHEN APPOINTMENT_STATUS IN ('Attended','Did Not Attend')
                     THEN COUNT_OF_APPOINTMENTS ELSE 0 END), 0
        ), 2
    )                                                       AS dna_rate_pct
FROM pcn_granular_clean
GROUP BY REGION_NAME
ORDER BY dna_rate_pct DESC;

-- 5c. DNA rate by Sub-ICB — ranked league table (97 locations)
SELECT
    SUB_ICB_LOCATION_CODE,
    SUB_ICB_LOCATION_NAME,
    REGION_NAME,
    SUM(CASE WHEN APPOINTMENT_STATUS = 'Did Not Attend'
             THEN COUNT_OF_APPOINTMENTS ELSE 0 END)         AS dna_count,
    SUM(CASE WHEN APPOINTMENT_STATUS IN ('Attended','Did Not Attend')
             THEN COUNT_OF_APPOINTMENTS ELSE 0 END)         AS total_appointments,
    ROUND(
        100.0
        * SUM(CASE WHEN APPOINTMENT_STATUS = 'Did Not Attend'
                   THEN COUNT_OF_APPOINTMENTS ELSE 0 END)
        / NULLIF(
            SUM(CASE WHEN APPOINTMENT_STATUS IN ('Attended','Did Not Attend')
                     THEN COUNT_OF_APPOINTMENTS ELSE 0 END), 0
        ), 2
    )                                                       AS dna_rate_pct
FROM pcn_granular_clean
GROUP BY SUB_ICB_LOCATION_CODE, SUB_ICB_LOCATION_NAME, REGION_NAME
ORDER BY dna_rate_pct DESC;

-- 5d. Top 10 and bottom 10 Sub-ICBs — for dashboard highlights
SELECT 'Top 10 Highest DNA Rate' AS category,
    SUB_ICB_LOCATION_NAME, REGION_NAME, dna_rate_pct
FROM (
    SELECT SUB_ICB_LOCATION_NAME, REGION_NAME,
        ROUND(100.0
            * SUM(CASE WHEN APPOINTMENT_STATUS = 'Did Not Attend'
                       THEN COUNT_OF_APPOINTMENTS ELSE 0 END)
            / NULLIF(SUM(CASE WHEN APPOINTMENT_STATUS IN ('Attended','Did Not Attend')
                             THEN COUNT_OF_APPOINTMENTS ELSE 0 END),0), 2) AS dna_rate_pct
    FROM pcn_granular_clean
    GROUP BY SUB_ICB_LOCATION_NAME, REGION_NAME
    ORDER BY dna_rate_pct DESC LIMIT 10
)
UNION ALL
SELECT 'Bottom 10 Lowest DNA Rate',
    SUB_ICB_LOCATION_NAME, REGION_NAME, dna_rate_pct
FROM (
    SELECT SUB_ICB_LOCATION_NAME, REGION_NAME,
        ROUND(100.0
            * SUM(CASE WHEN APPOINTMENT_STATUS = 'Did Not Attend'
                       THEN COUNT_OF_APPOINTMENTS ELSE 0 END)
            / NULLIF(SUM(CASE WHEN APPOINTMENT_STATUS IN ('Attended','Did Not Attend')
                             THEN COUNT_OF_APPOINTMENTS ELSE 0 END),0), 2) AS dna_rate_pct
    FROM pcn_granular_clean
    GROUP BY SUB_ICB_LOCATION_NAME, REGION_NAME
    ORDER BY dna_rate_pct ASC LIMIT 10
);


-- =============================================================
-- STEP 6: ANALYSIS — Q2: HOW HAS APPOINTMENT MODE SHIFTED?
-- Source: national_overview_clean (30 months — full trend)
--         pcn_granular_clean (21 months — mode vs DNA rate)
-- =============================================================

-- 6a. National DNA trend over time — from national overview
--     30 months; use this for the main trend line chart
SELECT
    APPOINTMENT_MONTH,
    ROUND(
        100.0
        * SUM(CASE WHEN APPOINTMENT_STATUS = 'Did Not Attend'
                   THEN APPOINTMENTS ELSE 0 END)
        / NULLIF(
            SUM(CASE WHEN APPOINTMENT_STATUS IN ('Attended','Did Not Attend')
                     THEN APPOINTMENTS ELSE 0 END), 0
        ), 2
    )                                                       AS national_dna_rate_pct
FROM national_overview_clean
GROUP BY APPOINTMENT_MONTH
ORDER BY APPOINTMENT_MONTH;

-- 6b. Mode mix shift over time — national overview
--     Reveals post-COVID shift toward Telephone/Video appointments
SELECT
    APPOINTMENT_MONTH,
    APPOINTMENT_MODE,
    SUM(APPOINTMENTS)                                       AS total_appointments,
    ROUND(
        100.0 * SUM(APPOINTMENTS)
        / SUM(SUM(APPOINTMENTS)) OVER (PARTITION BY APPOINTMENT_MONTH), 2
    )                                                       AS pct_of_month
FROM national_overview_clean
WHERE APPOINTMENT_STATUS IN ('Attended', 'Did Not Attend')
  AND APPOINTMENT_MODE != 'Unknown'
GROUP BY APPOINTMENT_MONTH, APPOINTMENT_MODE
ORDER BY APPOINTMENT_MONTH, APPOINTMENT_MODE;

-- 6c. DNA rate by appointment mode — from PCN granular
--     Answers: do patients DNA more for certain modes?
SELECT
    APPOINTMENT_MODE,
    SUM(CASE WHEN APPOINTMENT_STATUS = 'Did Not Attend'
             THEN COUNT_OF_APPOINTMENTS ELSE 0 END)         AS dna_count,
    SUM(CASE WHEN APPOINTMENT_STATUS IN ('Attended','Did Not Attend')
             THEN COUNT_OF_APPOINTMENTS ELSE 0 END)         AS total_appointments,
    ROUND(
        100.0
        * SUM(CASE WHEN APPOINTMENT_STATUS = 'Did Not Attend'
                   THEN COUNT_OF_APPOINTMENTS ELSE 0 END)
        / NULLIF(
            SUM(CASE WHEN APPOINTMENT_STATUS IN ('Attended','Did Not Attend')
                     THEN COUNT_OF_APPOINTMENTS ELSE 0 END), 0
        ), 2
    )                                                       AS dna_rate_pct
FROM pcn_granular_clean
WHERE APPOINTMENT_MODE != 'Unknown'
GROUP BY APPOINTMENT_MODE
ORDER BY dna_rate_pct DESC;

-- 6d. DNA rate by mode AND region — cross-cut
--     Reveals whether the mode effect differs by geography
SELECT
    REGION_NAME,
    APPOINTMENT_MODE,
    ROUND(
        100.0
        * SUM(CASE WHEN APPOINTMENT_STATUS = 'Did Not Attend'
                   THEN COUNT_OF_APPOINTMENTS ELSE 0 END)
        / NULLIF(
            SUM(CASE WHEN APPOINTMENT_STATUS IN ('Attended','Did Not Attend')
                     THEN COUNT_OF_APPOINTMENTS ELSE 0 END), 0
        ), 2
    )                                                       AS dna_rate_pct
FROM pcn_granular_clean
WHERE APPOINTMENT_MODE IN ('Face-to-Face', 'Telephone')
GROUP BY REGION_NAME, APPOINTMENT_MODE
ORDER BY REGION_NAME, APPOINTMENT_MODE;


-- =============================================================
-- STEP 7: ANALYSIS — Q3: IS THERE AN INEQUALITY PATTERN?
-- Source: pcn_granular_clean + deprivation_clean
--
-- JOIN STRATEGY:
-- pcn_granular_clean holds Sub-ICB level data.
-- deprivation_clean holds LSOA level data.
-- These two geographies do not share a direct key.
-- The join works by aggregating deprivation to Local Authority
-- (LA) level, then matching LA district codes to the Sub-ICB
-- area name using a partial text match on LA_DISTRICT_NAME.
-- This is an approximation — document it in your methodology.
-- A cleaner join would use an LSOA-to-Sub-ICB lookup table,
-- which NHS England publishes separately if needed.
-- =============================================================

-- 7a. Reusable view: DNA rate per Sub-ICB
CREATE VIEW IF NOT EXISTS dna_by_subicb AS
SELECT
    SUB_ICB_LOCATION_CODE,
    SUB_ICB_LOCATION_NAME,
    ICB_NAME,
    REGION_NAME,
    SUM(CASE WHEN APPOINTMENT_STATUS = 'Did Not Attend'
             THEN COUNT_OF_APPOINTMENTS ELSE 0 END)         AS dna_count,
    SUM(CASE WHEN APPOINTMENT_STATUS IN ('Attended','Did Not Attend')
             THEN COUNT_OF_APPOINTMENTS ELSE 0 END)         AS total_appointments,
    ROUND(
        100.0
        * SUM(CASE WHEN APPOINTMENT_STATUS = 'Did Not Attend'
                   THEN COUNT_OF_APPOINTMENTS ELSE 0 END)
        / NULLIF(
            SUM(CASE WHEN APPOINTMENT_STATUS IN ('Attended','Did Not Attend')
                     THEN COUNT_OF_APPOINTMENTS ELSE 0 END), 0
        ), 2
    )                                                       AS dna_rate_pct
FROM pcn_granular_clean
GROUP BY
    SUB_ICB_LOCATION_CODE,
    SUB_ICB_LOCATION_NAME,
    ICB_NAME,
    REGION_NAME;

-- 7b. Reusable view: average deprivation per local authority
--     Collapses LSOA-level IMD to LA level for joining
CREATE VIEW IF NOT EXISTS deprivation_by_la AS
SELECT
    LA_DISTRICT_CODE,
    LA_DISTRICT_NAME,
    ROUND(AVG(IMD_SCORE),  2)   AS avg_imd_score,
    ROUND(AVG(IMD_DECILE), 1)   AS avg_imd_decile,
    COUNT(LSOA_CODE)             AS lsoa_count
FROM deprivation_clean
WHERE IMD_DECILE IS NOT NULL
GROUP BY LA_DISTRICT_CODE, LA_DISTRICT_NAME;

-- 7c. DNA rate + deprivation — joined via ICB name text match
--     NOTE: This is an approximation join. Verify results
--     manually for any Sub-ICBs that return NULL deprivation.
--     Adjust the LIKE pattern if a match is not found.
SELECT
    d.SUB_ICB_LOCATION_NAME,
    d.REGION_NAME,
    d.dna_rate_pct,
    dep.LA_DISTRICT_NAME,
    dep.avg_imd_score,
    dep.avg_imd_decile,
    CASE
        WHEN dep.avg_imd_decile <= 2  THEN '1-2 (Most Deprived)'
        WHEN dep.avg_imd_decile <= 4  THEN '3-4'
        WHEN dep.avg_imd_decile <= 6  THEN '5-6'
        WHEN dep.avg_imd_decile <= 8  THEN '7-8'
        ELSE                               '9-10 (Least Deprived)'
    END                                                     AS deprivation_band
FROM dna_by_subicb d
JOIN deprivation_by_la dep
    ON UPPER(dep.LA_DISTRICT_NAME) LIKE '%'
       || UPPER(SUBSTR(d.SUB_ICB_LOCATION_NAME, 5,
              INSTR(d.SUB_ICB_LOCATION_NAME, ' ICB') - 5))
       || '%'
ORDER BY dep.avg_imd_score DESC;

-- 7d. Headline: average DNA rate by deprivation band
--     Your most important single output — export to Excel
SELECT
    CASE
        WHEN dep.avg_imd_decile <= 2  THEN '1-2 (Most Deprived)'
        WHEN dep.avg_imd_decile <= 4  THEN '3-4'
        WHEN dep.avg_imd_decile <= 6  THEN '5-6'
        WHEN dep.avg_imd_decile <= 8  THEN '7-8'
        ELSE                               '9-10 (Least Deprived)'
    END                                                     AS deprivation_band,
    COUNT(*)                                                AS area_count,
    ROUND(AVG(d.dna_rate_pct), 2)                           AS avg_dna_rate_pct,
    ROUND(MIN(d.dna_rate_pct), 2)                           AS min_dna_rate_pct,
    ROUND(MAX(d.dna_rate_pct), 2)                           AS max_dna_rate_pct
FROM dna_by_subicb d
JOIN deprivation_by_la dep
    ON UPPER(dep.LA_DISTRICT_NAME) LIKE '%'
       || UPPER(SUBSTR(d.SUB_ICB_LOCATION_NAME, 5,
              INSTR(d.SUB_ICB_LOCATION_NAME, ' ICB') - 5))
       || '%'
GROUP BY deprivation_band
ORDER BY MIN(dep.avg_imd_decile);


-- =============================================================
-- STEP 8: EXPORT QUERIES FOR EXCEL
-- Run each query, then right-click results > Export as CSV
-- Each feeds a specific chart type in your dashboard.
-- =============================================================

-- EXPORT A: National DNA trend line (30 months) → Line chart
--           Run query 6a and export

-- EXPORT B: Mode mix over time → Stacked area chart
--           Run query 6b and export

-- EXPORT C: DNA rate by mode → Horizontal bar chart
SELECT APPOINTMENT_MODE, dna_rate_pct
FROM (
    SELECT
        APPOINTMENT_MODE,
        ROUND(100.0
            * SUM(CASE WHEN APPOINTMENT_STATUS = 'Did Not Attend'
                       THEN COUNT_OF_APPOINTMENTS ELSE 0 END)
            / NULLIF(SUM(CASE WHEN APPOINTMENT_STATUS
                              IN ('Attended','Did Not Attend')
                             THEN COUNT_OF_APPOINTMENTS ELSE 0 END),0),2
        )                                                   AS dna_rate_pct
    FROM pcn_granular_clean
    WHERE APPOINTMENT_MODE != 'Unknown'
    GROUP BY APPOINTMENT_MODE
)
ORDER BY dna_rate_pct DESC;

-- EXPORT D: Regional DNA rates → Bar chart
--           Run query 5b and export

-- EXPORT E: Sub-ICB league table → Ranked table in Excel
--           Run query 5c and export

-- EXPORT F: Deprivation band vs DNA rate → Column chart
--           Run query 7d and export

-- EXPORT G: Mode vs DNA rate by region → Clustered bar chart
--           Run query 6d and export
