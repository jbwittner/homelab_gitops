# Prometheus + Grafana

Cœur du monitoring de l'hôte Docker : **Prometheus** (collecte) + **Grafana** (visualisation).
Grafana est exposé sur `grafana.wittnerlab.com` et authentifié en **OAuth2 via Authentik**.

## Services

| Conteneur | Image | Rôle |
|---|---|---|
| `monitoring_prometheus` | `prom/prometheus` | scrape & TSDB (rétention 15j / 5GB) |
| `monitoring_grafana` | `grafana/grafana` | dashboards (provisioning local `./dashboards`) |

Ports `9090` (Prometheus) et — selon exposition Dokploy — Grafana, liés à `127.0.0.1`.
La config de scrape est dans [`prometheus.yml`](prometheus.yml).

## Réseaux

| Réseau | Type | Rôle |
|---|---|---|
| `monitoring_net` | **externe** | scraper cAdvisor & node-exporter |
| `security_network` | **externe** | scraper CrowdSec ([`security/crowdsec`](../../security/crowdsec/README.md)) |
| `grafana_net` | bridge | Prometheus ↔ Grafana (datasource) |

À créer une fois : `docker network create monitoring_net` et `docker network create security_network`.

## Authentification (OAuth2 / Authentik)

Le login local est désactivé (`GF_AUTH_BASIC_ENABLED=false`, `GF_AUTH_DISABLE_LOGIN_FORM=true`).
Grafana délègue à [`authentik`](../../authentication/authentik/README.md) (generic OAuth2).
Mapping de rôle : membre du groupe `grafana_admins` → `GrafanaAdmin`, sinon `Viewer`.

## Variables d'environnement

Copier en `.env` (gitignored) et compléter les credentials OAuth fournis par Authentik :

| Variable | Rôle |
|---|---|
| `GF_AUTH_GENERIC_OAUTH_CLIENT_ID` | client ID de l'application Authentik |
| `GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET` | client secret associé |
