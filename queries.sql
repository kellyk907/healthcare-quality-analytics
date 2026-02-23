-- Recompute measures from base tables
-- Recompute measures from base tables (patients/encounters/conditions/procedures)
WITH params AS (
  SELECT
    '2024-01-01' AS year_start,
    '2024-12-31' AS year_end,
    '2023-01-01' AS lookback_start,
    '2024-06-30' AS asof_date
),

-- M1 Denominator: active female 50–74 with >=1 encounter in measurement year
m1_den AS (
  SELECT DISTINCT p.patient_id, p.race
  FROM patients p, params par
  JOIN encounters e ON e.patient_id = p.patient_id
  WHERE p.active_flag = 1
    AND p.sex = 'Female'
    AND (CAST((julianday(par.asof_date) - julianday(p.birth_date)) / 365.25 AS INTEGER)) BETWEEN 50 AND 74
    AND date(e.encounter_date) BETWEEN par.year_start AND par.year_end
),

-- M1 Numerator: mammogram screening within 2-year window (here: 2023-01-01 to 2024-12-31)
m1_num AS (
  SELECT DISTINCT d.patient_id
  FROM m1_den d, params par
  JOIN procedures pr ON pr.patient_id = d.patient_id
  WHERE pr.procedure_code = 'SCR-MAMMO'
    AND date(pr.procedure_date) BETWEEN par.lookback_start AND par.year_end
),

-- M2 Denominator: active patients with diabetes
m2_den AS (
  SELECT DISTINCT p.patient_id, p.race
  FROM patients p
  JOIN conditions c ON c.patient_id = p.patient_id
  WHERE p.active_flag = 1
    AND c.condition_name = 'Diabetes'
    AND c.active_flag = 1
),

-- M2 Numerator: HbA1c test during measurement year
m2_num AS (
  SELECT DISTINCT d.patient_id
  FROM m2_den d, params par
  JOIN procedures pr ON pr.patient_id = d.patient_id
  WHERE pr.procedure_code = 'LAB-HBA1C'
    AND date(pr.procedure_date) BETWEEN par.year_start AND par.year_end
)

SELECT
  'Preventive Screening (Mammogram-style)' AS measure,
  (SELECT COUNT(*) FROM m1_den) AS denominator,
  (SELECT COUNT(*) FROM m1_num) AS numerator,
  ROUND(CAST((SELECT COUNT(*) FROM m1_num) AS REAL) / NULLIF((SELECT COUNT(*) FROM m1_den),0), 3) AS rate
UNION ALL
SELECT
  'Diabetes Care (HbA1c test)' AS measure,
  (SELECT COUNT(*) FROM m2_den) AS denominator,
  (SELECT COUNT(*) FROM m2_num) AS numerator,
  ROUND(CAST((SELECT COUNT(*) FROM m2_num) AS REAL) / NULLIF((SELECT COUNT(*) FROM m2_den),0), 3) AS rate;

-- Monthly trends
WITH params AS (
  SELECT
    '2024-01-01' AS year_start,
    '2024-12-31' AS year_end,
    '2024-06-30' AS asof_date
),

months AS (
  SELECT date('2024-01-01') AS month_start
  UNION ALL
  SELECT date(month_start, '+1 month')
  FROM months
  WHERE month_start < date('2024-12-01')
),

m1_den AS (
  SELECT DISTINCT p.patient_id
  FROM patients p, params par
  JOIN encounters e ON e.patient_id = p.patient_id
  WHERE p.active_flag = 1
    AND p.sex = 'Female'
    AND (CAST((julianday(par.asof_date) - julianday(p.birth_date)) / 365.25 AS INTEGER)) BETWEEN 50 AND 74
    AND date(e.encounter_date) BETWEEN par.year_start AND par.year_end
),

m2_den AS (
  SELECT DISTINCT p.patient_id
  FROM patients p
  JOIN conditions c ON c.patient_id = p.patient_id
  WHERE p.active_flag = 1
    AND c.condition_name = 'Diabetes'
    AND c.active_flag = 1
)

SELECT
  'Preventive Screening (events per month)' AS series,
  strftime('%Y-%m', m.month_start) AS month,
  (SELECT COUNT(*) FROM m1_den) AS denominator,
  COUNT(DISTINCT CASE
    WHEN pr.procedure_code = 'SCR-MAMMO'
     AND date(pr.procedure_date) >= m.month_start
     AND date(pr.procedure_date) < date(m.month_start, '+1 month')
    THEN pr.patient_id END
  ) AS numerator,
  ROUND(
    CAST(COUNT(DISTINCT CASE
      WHEN pr.procedure_code = 'SCR-MAMMO'
       AND date(pr.procedure_date) >= m.month_start
       AND date(pr.procedure_date) < date(m.month_start, '+1 month')
      THEN pr.patient_id END
    ) AS REAL) / NULLIF((SELECT COUNT(*) FROM m1_den),0), 3
  ) AS rate
FROM months m
LEFT JOIN procedures pr ON pr.patient_id IN (SELECT patient_id FROM m1_den)
GROUP BY month

UNION ALL

SELECT
  'Diabetes HbA1c (events per month)' AS series,
  strftime('%Y-%m', m.month_start) AS month,
  (SELECT COUNT(*) FROM m2_den) AS denominator,
  COUNT(DISTINCT CASE
    WHEN pr.procedure_code = 'LAB-HBA1C'
     AND date(pr.procedure_date) >= m.month_start
     AND date(pr.procedure_date) < date(m.month_start, '+1 month')
    THEN pr.patient_id END
  ) AS numerator,
  ROUND(
    CAST(COUNT(DISTINCT CASE
      WHEN pr.procedure_code = 'LAB-HBA1C'
       AND date(pr.procedure_date) >= m.month_start
       AND date(pr.procedure_date) < date(m.month_start, '+1 month')
      THEN pr.patient_id END
    ) AS REAL) / NULLIF((SELECT COUNT(*) FROM m2_den),0), 3
  ) AS rate
FROM months m
LEFT JOIN procedures pr ON pr.patient_id IN (SELECT patient_id FROM m2_den)
GROUP BY month
ORDER BY series, month;

-- Target flags by race
WITH base AS (
  SELECT
    qe.measure_name,
    p.race,
    COUNT(*) AS denominator,
    SUM(qe.numerator_flag) AS numerator,
    CAST(SUM(qe.numerator_flag) AS REAL) / NULLIF(COUNT(*),0) AS rate
  FROM quality_events qe
  JOIN patients p ON p.patient_id = qe.patient_id
  WHERE qe.denominator_flag = 1
  GROUP BY qe.measure_name, p.race
)

SELECT
  measure_name,
  race,
  denominator,
  numerator,
  ROUND(rate, 3) AS rate,
  CASE
    WHEN measure_name = 'Preventive Screening (Mammogram-style)' AND rate < 0.75 THEN 'UNDER TARGET'
    WHEN measure_name = 'Diabetes Care (HbA1c test)' AND rate < 0.8 THEN 'UNDER TARGET'
    ELSE 'ON TRACK'
  END AS status
FROM base
ORDER BY measure_name, status DESC, rate ASC;
