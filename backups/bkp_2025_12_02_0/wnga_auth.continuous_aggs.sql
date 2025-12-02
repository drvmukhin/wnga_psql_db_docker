-- Continuous Aggregate: public.app_telem_series_1d
CREATE MATERIALIZED VIEW public.app_telem_series_1d
WITH (timescaledb.continuous) AS
 SELECT time_bucket('1 day'::interval, "time") AS bucket,
    user_id,
    schema_id,
    schema_version,
    metric,
    dimension_hash,
    percentile_cont((0.5)::double precision) WITHIN GROUP (ORDER BY value) AS p50,
    percentile_cont((0.95)::double precision) WITHIN GROUP (ORDER BY value) AS p95,
    avg(value) AS avg,
    max(value) AS max,
    min(value) AS min,
    sum(value) AS sum
   FROM app_telem_series
  GROUP BY (time_bucket('1 day'::interval, "time")), user_id, schema_id, schema_version, metric, dimension_hash;;

-- Continuous Aggregate: public.app_telem_series_1h
CREATE MATERIALIZED VIEW public.app_telem_series_1h
WITH (timescaledb.continuous) AS
 SELECT time_bucket('01:00:00'::interval, "time") AS bucket,
    user_id,
    schema_id,
    schema_version,
    metric,
    dimension_hash,
    percentile_cont((0.5)::double precision) WITHIN GROUP (ORDER BY value) AS p50,
    percentile_cont((0.95)::double precision) WITHIN GROUP (ORDER BY value) AS p95,
    avg(value) AS avg,
    max(value) AS max,
    min(value) AS min,
    sum(value) AS sum
   FROM app_telem_series
  GROUP BY (time_bucket('01:00:00'::interval, "time")), user_id, schema_id, schema_version, metric, dimension_hash;;

