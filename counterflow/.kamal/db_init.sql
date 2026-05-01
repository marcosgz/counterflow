-- Runs once when the TimescaleDB accessory container is created for the
-- first time (mounted at /docker-entrypoint-initdb.d/01_init.sql).
-- Sets up the timescaledb extension on the counterflow_prod database so
-- our migrations' `create_hypertable` calls succeed.
CREATE EXTENSION IF NOT EXISTS timescaledb;
