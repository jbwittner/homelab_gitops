# taerar — stacks Docker Compose (Dokploy)

Environnement **Docker** du homelab : un ensemble de stacks **Docker Compose** déployées et
gérées via **Dokploy**. Contrairement à [`neltharion/`](../neltharion/README.md) (Kubernetes +
Argo CD GitOps), il n'y a pas de réconciliation Git automatique ici — chaque stack est un
`compose.yaml` auto-contenu dans son dossier.

## Organisation

Un dossier **par stack**, regroupé par catégorie : `taerar/<categorie>/<stack>/compose.yaml`
(+ `example.env`, fichiers de config, `README.md`). Les stacks retirées vivent sous
[`taerar/archive/`](archive/).

## Conventions

- **Nommage des conteneurs** : `<categorie>_<stack>_<service>`
  (ex. `messaging_postfix_mail_sender`, `monitoring_prometheus`).
- **Secrets** : chaque stack qui en a besoin fournit un `example.env` → le copier en `.env`
  (gitignored) et compléter. Les fichiers sensibles montés (clés, certs) passent par le
  bind-mount Dokploy « Files/Mounts » (`files/…`).
- **Réseaux externes partagés** : certaines stacks communiquent via des réseaux Docker
  **externes**, à créer **une seule fois** sur l'hôte avant de lancer les stacks concernées :

  | Réseau | Créé par | Relie |
  |---|---|---|
  | `messaging_net` | `docker network create messaging_net` | Postfix ↔ apps clientes (Forgejo, Authentik) |
  | `monitoring_net` | `docker network create monitoring_net` | Prometheus ↔ cAdvisor / node-exporter |
  | `security_network` | `docker network create security_network` | CrowdSec ↔ Prometheus |
  | `grafana_net` | créé par la stack `prometheus-grafana` | Prometheus ↔ Grafana |

- **Runs one-shot** : certaines stacks ne tournent pas en continu (`restart: "no"`) —
  Renovate (run unique), certbot de Postfix (obtention du cert puis arrêt).

## Stacks déployées

| Catégorie | Stack | Rôle | README |
|---|---|---|---|
| authentication | authentik | SSO / OIDC (IdP) | [README](authentication/authentik/README.md) |
| maintenance | renovate | mises à jour de dépendances (Forgejo) | [README](maintenance/renovate/README.md) |
| messaging | postfix | relais SMTP interne (TLS + DKIM) | [README](messaging/postfix/README.md) |
| monitoring | prometheus-grafana | collecte + dashboards (OAuth Authentik) | [README](monitoring/prometheus-grafana/README.md) |
| monitoring | cadvisor | métriques par conteneur | [README](monitoring/cadvisor/README.md) |
| monitoring | node-exporter | métriques de l'hôte | [README](monitoring/node-exporter/README.md) |
| security | crowdsec | détection d'intrusion | [README](security/crowdsec/README.md) |
| source-control | forgejo | forge Git + registry | [README](source-control/forgejo/README.md) |
| source-control | forgejo-runner | runner CI (DinD) | [README](source-control/forgejo-runner/README.md) |
| tools | homepage | dashboard d'accueil | [README](tools/homepage/README.md) |
| tools | it-tools | outils dev web | [README](tools/it-tools/README.md) |
| tools | n8n | automatisation de workflows | [README](tools/n8n/README.md) |
| tools | shiori | gestionnaire de marque-pages | [README](tools/shiori/README.md) |
| tools | swagger-editor | éditeur OpenAPI | [README](tools/swagger-editor/README.md) |

## Lancer une stack

```bash
# depuis le dossier de la stack
docker network create messaging_net   # si la stack utilise un réseau externe partagé (une fois)
cp example.env .env                    # puis compléter les valeurs
docker compose --env-file .env up -d
```
