# Homepage

Tableau de bord d'accueil du homelab (`gethomepage`) — `tools_homepage`.

## Détails

- Image `ghcr.io/gethomepage/homepage`.
- Config statique montée en lecture seule depuis `./config/` :
  `settings.yaml`, `bookmarks.yaml`, `services.yaml`, `widgets.yaml`.
- Monte `docker.sock` (lecture seule) pour les widgets de découverte Docker.
- `HOMEPAGE_ALLOWED_HOSTS: "*"` (à restreindre si besoin derrière le reverse-proxy).

Pas de fichier `.env` ; tout passe par les YAML de `./config/`.
