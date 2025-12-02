-- Hypertable: public.app_telem_series
SELECT create_hypertable(
  'public.app_telem_series',
  'time',
  chunk_time_interval => 604800000000,
  if_not_exists => true,
  migrate_data => true
);

