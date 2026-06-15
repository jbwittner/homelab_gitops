# node-exporter

Exporte les métriques **de l'hôte** (CPU, mémoire, disque, réseau) — `monitoring_node_exporter`,
scrapé par Prometheus.

## Détails

- Image `prom/node-exporter`, `privileged`, monte `/proc`, `/sys`, `/` en lecture seule.
- Port `9100` lié **uniquement à `127.0.0.1`** ; le scrape Prometheus passe par le réseau
  partagé.

## Réseau

| Réseau | Type | Rôle |
|---|---|---|
| `monitoring_net` | **externe** | scrape par [`prometheus-grafana`](../prometheus-grafana/README.md) |

À créer une fois : `docker network create monitoring_net`.

Pas de fichier `.env`.
