CREATE OR REPLACE VIEW v_fact_geo AS
SELECT f.*, g.country_name, g.sub_region, g.region, g.col_index
FROM fact_survey_response f
JOIN dim_geography g USING (geography_key)
WHERE f.comp_adjusted IS NOT NULL;


-- Q1: top 15 paesi per mediana di potere d'acquisto, soglia 30 rispondenti
SELECT country_name,
       count(*)                                                       AS n,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY comp_usd)::numeric, 0)      AS mediana_usd,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY comp_adjusted)::numeric, 0) AS mediana_adj
FROM v_fact_geo
GROUP BY country_name
HAVING count(*) >= 30
ORDER BY mediana_adj DESC
LIMIT 15;


-- Q2: confronto tra ranking nominale e reale con window function
WITH per_paese AS (
    SELECT country_name,
           count(*) AS n,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY comp_usd)      AS med_usd,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY comp_adjusted) AS med_adj
    FROM v_fact_geo
    GROUP BY country_name
    HAVING count(*) >= 30
)
SELECT country_name, n,
       round(med_usd::numeric)  AS mediana_usd,
       round(med_adj::numeric)  AS mediana_adj,
       rank() OVER (ORDER BY med_usd  DESC) AS rank_nominale,
       rank() OVER (ORDER BY med_adj DESC)  AS rank_reale,
       rank() OVER (ORDER BY med_usd DESC)
         - rank() OVER (ORDER BY med_adj DESC) AS posizioni_guadagnate
FROM per_paese
ORDER BY posizioni_guadagnate DESC, mediana_adj DESC
LIMIT 20;


-- Q3: roll up su region e sub region con GROUP BY ROLLUP
SELECT CASE GROUPING(region)     WHEN 1 THEN '** MONDO **' ELSE region END     AS region,
       CASE GROUPING(sub_region) WHEN 1 THEN '(tutte)'     ELSE sub_region END AS sub_region,
       count(*) AS n,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY comp_adjusted)::numeric, 0) AS mediana_adj
FROM v_fact_geo
GROUP BY ROLLUP (region, sub_region)
ORDER BY GROUPING(region), region, GROUPING(sub_region), mediana_adj DESC;


-- Q4: mediana per fascia di esperienza incrociata con region
SELECT e.experience_band,
       g.region,
       count(*) AS n,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY f.comp_adjusted)::numeric, 0) AS mediana_adj
FROM fact_survey_response f
JOIN dim_experience e USING (experience_key)
JOIN dim_geography  g USING (geography_key)
WHERE f.comp_adjusted IS NOT NULL
  AND e.experience_band <> 'Unknown'
GROUP BY e.experience_band, g.region
HAVING count(*) >= 30
ORDER BY e.experience_band, mediana_adj DESC;


-- Q5: classifica paesi solo per sviluppatori full stack
SELECT v.country_name,
       count(*) AS n,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY v.comp_adjusted)::numeric, 0) AS mediana_adj
FROM v_fact_geo v
JOIN dim_devtype d USING (devtype_key)
WHERE d.devtype_name = 'Developer, full-stack'
GROUP BY v.country_name
HAVING count(*) >= 30
ORDER BY mediana_adj DESC
LIMIT 10;


-- Q6: confronto remote e in person nella stessa riga con FILTER
SELECT g.region,
       count(*) FILTER (WHERE r.work_mode = 'Remote')    AS n_remote,
       count(*) FILTER (WHERE r.work_mode = 'In-person') AS n_inperson,
       round((percentile_cont(0.5) WITHIN GROUP (ORDER BY f.comp_adjusted)
              FILTER (WHERE r.work_mode = 'Remote'))::numeric, 0)    AS med_adj_remote,
       round((percentile_cont(0.5) WITHIN GROUP (ORDER BY f.comp_adjusted)
              FILTER (WHERE r.work_mode = 'In-person'))::numeric, 0) AS med_adj_inperson
FROM fact_survey_response f
JOIN dim_remotework r USING (remotework_key)
JOIN dim_geography  g USING (geography_key)
WHERE f.comp_adjusted IS NOT NULL
GROUP BY g.region
HAVING count(*) FILTER (WHERE r.work_mode = 'Remote') >= 30
   AND count(*) FILTER (WHERE r.work_mode = 'In-person') >= 30
ORDER BY med_adj_remote DESC;


-- Q7: mediana per linguaggio tramite la bridge table
SELECT l.language_name,
       count(*) AS n_rispondenti,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY v.comp_adjusted)::numeric, 0) AS mediana_adj
FROM v_fact_geo v
JOIN bridge_response_language b USING (fact_key)
JOIN dim_language l USING (language_key)
GROUP BY l.language_name
HAVING count(*) >= 200
ORDER BY mediana_adj DESC
LIMIT 15;


-- Q8: stessa top 10 di Q1 ma solo full time, verifica di robustezza
SELECT v.country_name,
       count(*) AS n,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY v.comp_adjusted)::numeric, 0) AS mediana_adj
FROM v_fact_geo v
JOIN dim_employment e USING (employment_key)
WHERE e.employment_status = 'Employed, full-time'
GROUP BY v.country_name
HAVING count(*) >= 30
ORDER BY mediana_adj DESC
LIMIT 10;


-- Q9a: mediana pooled contro mediana a pesi uguali per region
WITH country_medians AS (
    SELECT country_name, region,
           count(*) AS n,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY comp_adjusted) AS country_med_adj
    FROM v_fact_geo
    GROUP BY country_name, region
    HAVING count(*) >= 30
),
pooled AS (
    SELECT region,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY comp_adjusted) AS pooled_median
    FROM v_fact_geo
    GROUP BY region
),
equal_weighted AS (
    SELECT region,
           count(*) AS n_paesi,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY country_med_adj) AS eq_weighted_median
    FROM country_medians
    GROUP BY region
)
SELECT p.region,
       ew.n_paesi,
       round(p.pooled_median::numeric, 0)        AS pooled_respondent_weighted,
       round(ew.eq_weighted_median::numeric, 0)  AS country_equal_weighted,
       round((p.pooled_median - ew.eq_weighted_median)::numeric, 0) AS scarto
FROM pooled p
JOIN equal_weighted ew USING (region)
ORDER BY scarto DESC;

-- Q9b: stesso confronto ma a livello mondo, una sola riga
WITH country_medians AS (
    SELECT country_name,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY comp_adjusted) AS country_med_adj
    FROM v_fact_geo
    GROUP BY country_name
    HAVING count(*) >= 30
)
SELECT
  (SELECT round(percentile_cont(0.5) WITHIN GROUP (ORDER BY comp_adjusted)::numeric, 0)
   FROM v_fact_geo)                                                          AS mondo_pooled,
  (SELECT round(percentile_cont(0.5) WITHIN GROUP (ORDER BY country_med_adj)::numeric, 0)
   FROM country_medians)                                                     AS mondo_country_equal_weighted,
  (SELECT count(*) FROM country_medians)                                     AS n_paesi;

-- Q9c: stesso confronto ma per sub region, verifica diretta su Est e Ovest Europa
WITH country_medians AS (
    SELECT country_name, sub_region,
           count(*) AS n,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY comp_adjusted) AS country_med_adj
    FROM v_fact_geo
    GROUP BY country_name, sub_region
    HAVING count(*) >= 30
),
pooled AS (
    SELECT sub_region,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY comp_adjusted) AS pooled_median
    FROM v_fact_geo
    GROUP BY sub_region
),
equal_weighted AS (
    SELECT sub_region,
           count(*) AS n_paesi,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY country_med_adj) AS eq_weighted_median
    FROM country_medians
    GROUP BY sub_region
)
SELECT p.sub_region,
       ew.n_paesi,
       round(p.pooled_median::numeric, 0)        AS pooled_respondent_weighted,
       round(ew.eq_weighted_median::numeric, 0)  AS country_equal_weighted,
       round((p.pooled_median - ew.eq_weighted_median)::numeric, 0) AS scarto
FROM pooled p
JOIN equal_weighted ew USING (sub_region)
ORDER BY scarto DESC;
