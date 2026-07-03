-- 1. Univers CrowdSec
CREATE USER crowdsec_user WITH PASSWORD 'crowd_pass_123';
CREATE DATABASE crowdsec_db;
GRANT ALL PRIVILEGES ON DATABASE crowdsec_db TO crowdsec_user;

-- CORRECTIF : Donner les droits sur le schéma public de crowdsec_db
\c crowdsec_db
GRANT ALL ON SCHEMA public TO crowdsec_user;

-- 2. Univers Metabase
CREATE USER metabase_user WITH PASSWORD 'meta_pass_123';
CREATE DATABASE metabase_db;
GRANT ALL PRIVILEGES ON DATABASE metabase_db TO metabase_user;

-- CORRECTIF : Donner les droits sur le schéma public de metabase_db
\c metabase_db
GRANT ALL ON SCHEMA public TO metabase_user;

-- 3. Pont de lecture pour Metabase sur les données CrowdSec
\c crowdsec_db
GRANT CONNECT ON DATABASE crowdsec_db TO metabase_user;
GRANT USAGE ON SCHEMA public TO metabase_user;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO metabase_user;

ALTER DEFAULT PRIVILEGES FOR USER crowdsec_user IN SCHEMA public 
GRANT SELECT ON TABLES TO metabase_user;
