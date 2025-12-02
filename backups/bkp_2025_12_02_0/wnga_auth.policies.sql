-- Refresh policy for continuous aggregate: public.app_telem_series_1d
SELECT add_continuous_aggregate_policy(
  'public.app_telem_series_1d',
  start_offset => INTERVAL '30 days',
  end_offset => INTERVAL '1 day',
  schedule_interval => INTERVAL '86400.000000 seconds',
  if_not_exists => true
);

-- Refresh policy for continuous aggregate: public.app_telem_series_1h
SELECT add_continuous_aggregate_policy(
  'public.app_telem_series_1h',
  start_offset => INTERVAL '7 days',
  end_offset => INTERVAL '01:00:00',
  schedule_interval => INTERVAL '300.000000 seconds',
  if_not_exists => true
);

