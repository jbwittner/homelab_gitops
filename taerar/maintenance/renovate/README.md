# Renovate (Forgejo)

Renovate **self-hosted (CLI)** lancé en one-shot via Docker Compose (`restart: "no"` — le
conteneur s'arrête une fois le run terminé). Plateforme **Forgejo** : il scanne les repos
de l'instance Forgejo (`RENOVATE_AUTODISCOVER: "true"`) et ouvre des PRs de mise à jour.

## Variables d'environnement

Copier `example.env` en `.env` et compléter. Deux tokens, deux rôles distincts :

| Variable | Mappé sur | Plateforme | Rôle |
|----------|-----------|-----------|------|
| `RENOVATE_FORGEJO_TOKEN`    | `RENOVATE_TOKEN`           | Forgejo    | **lecture + écriture** : cloner, pousser les branches, ouvrir les PRs |
| `RENOVATE_GITHUB_COM_TOKEN` | `RENOVATE_GITHUB_COM_TOKEN` | github.com | **lecture seule** : versions + changelogs des deps hébergées sur GitHub |

### Pourquoi un token github.com alors que la plateforme est Forgejo ?

La plateforme cible (où Renovate écrit les PRs) est Forgejo, mais **la plupart des
dépendances** (images Docker, actions, modules, charts…) sont hébergées sur **github.com**.
Pour chaque dépendance, Renovate interroge l'API github.com afin de :

- **découvrir les nouvelles versions** (tags/releases) ;
- **récupérer les release notes / changelogs** affichés dans le corps des PRs.

Sans token, ces appels sont **anonymes** et github.com applique une limite de **60
requêtes/heure par IP** : le run se fait rapidement `HTTP 403 rate limit exceeded`, les PRs
sortent sans changelog ou échouent. Avec un token, la limite passe à **5000 req/h** et les
release notes sont correctement remontées.

### Droits nécessaires pour `RENOVATE_GITHUB_COM_TOKEN`

C'est un **PAT en lecture seule**, jamais en écriture (ce token ne crée aucune PR) :

| Variante | Où | Scopes |
|----------|----|----|
| **Classic** (le plus simple) | GitHub → Settings → Developer settings → *Tokens (classic)* | `public_repo` — ou **aucun scope** si seules des deps publiques sont suivies |
| **Fine-grained** | GitHub → Settings → Developer settings → *Fine-grained tokens* | Repository access = *Public repositories (read-only)*, permission **Contents: Read** + **Metadata: Read** |

> ⚠️ Ne **jamais** mettre de scope d'écriture (`repo`, `workflow`, Contents: RW…) sur ce
> token : il sert uniquement à lire des métadonnées publiques. Le droit d'écriture vit côté
> Forgejo (`RENOVATE_FORGEJO_TOKEN`).

## Lancer un run

```bash
docker compose --env-file .env up
```

Le conteneur scanne les repos, ouvre/maj les PRs sur Forgejo, puis s'arrête.
