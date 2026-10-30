-- Read-only user `grafana` for the indexer database (ADR-0008, Grafana reads
-- its tables). Runs on every `make up` (service grafana-db-user), so it is
-- safe to run again: it creates the role once and then only updates it.
-- psql variable: pw = password from the secret grafana_db_password.

SELECT 'CREATE ROLE grafana LOGIN'
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'grafana') \gexec

ALTER ROLE grafana WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD :'pw';
-- Even a query that tries to write fails
ALTER ROLE grafana SET default_transaction_read_only = on;

GRANT CONNECT ON DATABASE pouw TO grafana;
GRANT USAGE ON SCHEMA public TO grafana;
-- Tables that exist now, and the ones the indexer (user pouw) creates later
GRANT SELECT ON ALL TABLES IN SCHEMA public TO grafana;
ALTER DEFAULT PRIVILEGES FOR ROLE pouw IN SCHEMA public GRANT SELECT ON TABLES TO grafana;
