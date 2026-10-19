-- Pulls one row per ICU stay with first-24h vitals + labs and a died/survived flag.
-- Runs on the MIMIC-III BigQuery copy (physionet-data.mimiciii_clinical).
-- I aggregate the huge chartevents/labevents tables here so I only download a
-- small ~53k-row summary, not the raw hundreds of millions of rows. I've been accustomed
-- to local dev on my PC, which is admittedly less reproducible for others, but I did
-- not have adequate time to adjust my workflow to be more reproducible for others. I apologize!
--
-- To get the data out: run this in the BigQuery console, save results to a table,
-- then export that table to a GCS bucket and download it. (The direct "save
-- results" download was truncating the export and dropping about 10% of records)
--
-- itemids I'm pulling (MIMIC has two charting systems, so most things have 2+ ids):
--   heart rate 211/220045 | sysBP 51,442,455,6701,220179,220050
--   resp rate 615,618,220210,224690 | spo2 646,220277
--   temp F 223761,678  temp C 223762,676
--   creatinine 50912 | BUN 51006 | WBC 51300,51301 | hemoglobin 51222
--   platelet 51265 | lactate 50813 | bicarbonate 50882 | glucose 50931

WITH base AS (
  -- one row per ICU stay: the 24h window plus the mortality label
  SELECT
    ie.subject_id,
    ie.hadm_id,
    ie.icustay_id,
    ie.intime,
    DATETIME_ADD(ie.intime, INTERVAL 24 HOUR) AS window_end,
    -- MIMIC bumps ages over 89 up to ~300 to de-identify, 
    -- so cap our analysis to those between 16 and 90
    LEAST(DATETIME_DIFF(ie.intime, pat.dob, YEAR), 90) AS age,
    pat.gender,
    adm.admission_type,
    adm.hospital_expire_flag AS mortality      -- what I'm predicting
  FROM `physionet-data.mimiciii_clinical.icustays` ie
  JOIN `physionet-data.mimiciii_clinical.patients`   pat ON ie.subject_id = pat.subject_id
  JOIN `physionet-data.mimiciii_clinical.admissions` adm ON ie.hadm_id   = adm.hadm_id
  WHERE DATETIME_DIFF(ie.intime, pat.dob, YEAR) >= 16 -- aforementioned, adults only
),

vitals AS (
  -- summarize each stay's vitals over the first 24h
  SELECT
    b.icustay_id,
    AVG(CASE WHEN ce.itemid IN (211,220045) THEN ce.valuenum END) AS hr_mean,
    MIN(CASE WHEN ce.itemid IN (211,220045) THEN ce.valuenum END) AS hr_min,
    MAX(CASE WHEN ce.itemid IN (211,220045) THEN ce.valuenum END) AS hr_max,
    MIN(CASE WHEN ce.itemid IN (51,442,455,6701,220179,220050) THEN ce.valuenum END) AS sbp_min,
    MAX(CASE WHEN ce.itemid IN (51,442,455,6701,220179,220050) THEN ce.valuenum END) AS sbp_max,
    AVG(CASE WHEN ce.itemid IN (615,618,220210,224690) THEN ce.valuenum END) AS resp_mean,
    MIN(CASE WHEN ce.itemid IN (646,220277) THEN ce.valuenum END) AS spo2_min,
    -- convert all temperatures to celcius
    AVG(CASE
          WHEN ce.itemid IN (223762,676) THEN ce.valuenum
          WHEN ce.itemid IN (223761,678) THEN (ce.valuenum - 32) / 1.8
        END) AS temp_c_mean
  FROM base b
  JOIN `physionet-data.mimiciii_clinical.chartevents` ce
    ON ce.icustay_id = b.icustay_id
   AND ce.charttime BETWEEN b.intime AND b.window_end -- first 24h only
   AND ce.valuenum IS NOT NULL
   AND ce.error IS DISTINCT FROM 1  -- drop flagged-error rows
  GROUP BY b.icustay_id
),

labs AS (
  -- same idea for labs. these join on hadm_id since labs aren't tied to an icustay
  SELECT
    b.icustay_id,
    MAX(CASE WHEN le.itemid = 50912 THEN le.valuenum END) AS creatinine_max,
    MAX(CASE WHEN le.itemid = 51006 THEN le.valuenum END) AS bun_max,
    MAX(CASE WHEN le.itemid IN (51300,51301) THEN le.valuenum END) AS wbc_max,
    MIN(CASE WHEN le.itemid = 51222 THEN le.valuenum END) AS hemoglobin_min,
    MIN(CASE WHEN le.itemid = 51265 THEN le.valuenum END) AS platelet_min,
    MAX(CASE WHEN le.itemid = 50813 THEN le.valuenum END) AS lactate_max,
    MIN(CASE WHEN le.itemid = 50882 THEN le.valuenum END) AS bicarbonate_min,
    MAX(CASE WHEN le.itemid = 50931 THEN le.valuenum END) AS glucose_max
  FROM base b
  JOIN `physionet-data.mimiciii_clinical.labevents` le
    ON le.hadm_id = b.hadm_id
   AND le.charttime BETWEEN b.intime AND b.window_end  -- first 24h only
   AND le.valuenum IS NOT NULL
  GROUP BY b.icustay_id
)

-- stitch it together. LEFT JOIN so stays with no vitals/labs still show up
-- (those just come through as nulls, which I fill in later in the notebook).
SELECT
  base.icustay_id,
  base.age,
  base.gender,
  base.admission_type,
  vitals.hr_mean, vitals.hr_min, vitals.hr_max,
  vitals.sbp_min, vitals.sbp_max,
  vitals.resp_mean, vitals.spo2_min, vitals.temp_c_mean,
  labs.creatinine_max, labs.bun_max, labs.wbc_max,
  labs.hemoglobin_min, labs.platelet_min, labs.lactate_max,
  labs.bicarbonate_min, labs.glucose_max,
  base.mortality
FROM base
LEFT JOIN vitals ON vitals.icustay_id = base.icustay_id
LEFT JOIN labs   ON labs.icustay_id   = base.icustay_id;

-- quick gut check I ran separately on the results: SELECT mortality, COUNT(*) grouped by mortality.
-- came back ~12% deaths, which feels about right from some research (say ranges from 5-20% in some literature.)
