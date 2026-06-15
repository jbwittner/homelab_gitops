# n8n

Plateforme d'automatisation de workflows (`docker.n8n.io/n8nio/n8n`). Exposé sur
`n8n.wittnerlab.com`.

## Services

| Conteneur | Image | Rôle |
|---|---|---|
| `n8n` | `n8nio/n8n` | UI + moteur de workflows (port `5678`) |
| `n8n-db` | `postgres:18` | base de n8n (db `n8n`) |
| `apps-db` | `postgres:18` | base PostgreSQL séparée (db `apps`) pour les workflows applicatifs |

## Variables d'environnement

Copier `example.env` en `.env` (gitignored) et compléter — toutes **requises** :

| Variable | Rôle |
|---|---|
| `DB_PASSWORD` | mot de passe PostgreSQL n8n (`n8n-db` + n8n) |
| `N8N_ENCRYPTION_KEY` | clé de chiffrement des credentials n8n (**ne pas changer après le 1ᵉʳ run**) |
| `APPS_DB_PASSWORD` | mot de passe de la base `apps-db` |

> ⚠️ Conserver `N8N_ENCRYPTION_KEY` : la perdre rend les credentials stockés illisibles.
