# Documentation

Fichier `acquis.yaml`

```yaml
source: docker
container_name:
  - dokploy-traefik
labels:
  type: traefik
```

Fichier `init.sql`

```sql
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
```

fichier `config.yaml`

```yaml
common:
  log_media: stdout
  log_level: info
  log_dir: /var/log/
config_paths:
  config_dir: /etc/crowdsec/
  data_dir: /var/lib/crowdsec/data/
  simulation_path: /etc/crowdsec/simulation.yaml
  hub_dir: /etc/crowdsec/hub/
  index_path: /etc/crowdsec/hub/.index.json
  notification_dir: /etc/crowdsec/notifications/
  plugin_dir: /usr/local/lib/crowdsec/plugins/
crowdsec_service:
  acquisition_path: /etc/crowdsec/acquis.yaml
  acquisition_dir: /etc/crowdsec/acquis.d
  parser_routines: 1
plugin_config:
  user: nobody
  group: nobody
cscli:
  output: human
db_config:
  log_level: info
  type: postgres
  user: crowdsec_user
  password: crowd_pass_123
  db_name: crowdsec_db
  host: db
  port: 5432
  flush:
    max_items: 5000
    max_age: 7d
api:
  client:
    insecure_skip_verify: false
    credentials_path: /etc/crowdsec/local_api_credentials.yaml
  server:
    log_level: info
    listen_uri: 0.0.0.0:8080
    profiles_path: /etc/crowdsec/profiles.yaml
    trusted_ips:
      - 127.0.0.1
      - ::1
    online_client:
      credentials_path: /etc/crowdsec/online_api_credentials.yaml
    enable: true
prometheus:
  enabled: true
  level: full
  listen_addr: 0.0.0.0
  listen_port: 6060
```

Variables d'environnement à définir dans un fichier `.env` (non inclus dans le dépôt pour des raisons de sécurité) :

```env
PG_ADMIN_USER=postgres_admin
PG_ADMIN_PASSWORD=admin_password_super_secret
PG_USER=metabase_user
PG_PASSWORD=metabase_pass_123
PG_DBNAME=metabase_db
```