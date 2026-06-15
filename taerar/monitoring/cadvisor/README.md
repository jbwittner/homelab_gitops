# cAdvisor

Exporte les métriques **par conteneur Docker** (`monitoring_cadvisor`), scrapé par Prometheus.

## Détails

- Image `ghcr.io/google/cadvisor`, `privileged` (lecture de `/`, `/var/run`, `/sys`,
  `/var/lib/docker`).
- Limité aux conteneurs Docker (`--docker_only=true`) ; de nombreuses métriques redondantes
  avec node-exporter sont désactivées pour économiser CPU/RAM.
- Port `8080` lié **uniquement à `127.0.0.1`** sur l'hôte ; le scrape Prometheus passe par le
  réseau partagé.

## Réseau

| Réseau | Type | Rôle |
|---|---|---|
| `monitoring_net` | **externe** | scrape par [`prometheus-grafana`](../prometheus-grafana/README.md) |

À créer une fois : `docker network create monitoring_net`.

Pas de fichier `.env`.
