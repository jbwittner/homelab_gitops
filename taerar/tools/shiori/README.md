# Shiori

Gestionnaire de marque-pages auto-hébergé (`go-shiori/shiori`) — `tools-shiori`. Stockage
SQLite persisté dans le volume `shiori-data`.

## Variables d'environnement

Créer un `.env` (gitignored) avec :

| Variable | Rôle |
|---|---|
| `SHIORI_SECRET_KEY` | clé de session HTTP (chaîne aléatoire forte) |

PostgreSQL/MySQL sont possibles (cf. `SHIORI_DATABASE_URL` commenté dans `compose.yaml`) mais
SQLite est utilisé par défaut. Exposé via le reverse-proxy Dokploy (port interne `8080`).
