# Forgejo Runner

Runner CI **self-hosted** pour l'instance [`forgejo`](../forgejo/README.md), avec Docker-in-Docker
pour exécuter les jobs en conteneurs.

## Services

| Conteneur | Image | Rôle |
|---|---|---|
| `source_control_forgejo_runner` | `data.forgejo.org/forgejo/runner` | daemon runner, prend les jobs |
| `source_control_docker_dind_forgejo_runner` | `docker:dind` (`privileged`) | démon Docker isolé pour les jobs (`tcp://...:2375`, sans TLS) |

## Réseau

| Réseau | Type | Rôle |
|---|---|---|
| `forgejo-net` | bridge interne | runner ↔ dind |

## Configuration

La config du runner est montée depuis un bind-mount Dokploy « Files/Mounts » :
`files/runner-config.yaml` → `/data/runner-config.yml`. Elle contient l'URL de l'instance
Forgejo et le token d'enregistrement du runner (à générer côté Forgejo :
**Site Administration → Actions → Runners → Create new runner**).

Pas de fichier `.env`.
