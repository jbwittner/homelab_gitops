# renovate — neltharion

Renovate **self-hosted (CLI)** exécuté en `CronJob` Kubernetes. Pas de plateforme Mend
hébergée : l'image officielle `renovate/renovate` est lancée périodiquement, scanne les
dépôts configurés et ouvre des PRs de mise à jour.

**Deux CronJobs, un par plateforme** (deux CLI distincts) :

| CronJob | Plateforme | Planification | Périmètre | Secret (envFrom) |
|---------|-----------|---------------|-----------|------------------|
| `renovate-github`  | `github`  | `@daily` (00h UTC) | `jbwittner/infrastructure`, `jbwittner/bankwiz_server` | `renovate-github-env` |
| `renovate-forgejo` | `forgejo` | `0 1 * * *` (01h UTC) | ⚠️ à définir (`RENOVATE_REPOSITORIES`) | `renovate-forgejo-env` |

Image commune : `renovate/renovate:43.177.9`. Chaque `cronjob-*.yaml` est **auto-contenu**
(la config commune est dupliquée entre les deux — choix assumé, cohérent avec l'ethos « flat
& simple » du repo). Toute la config passe par des **variables d'environnement** ; chaque
token arrive en bloc via `envFrom: secretRef` sur le Secret scellé de la plateforme.

> ⚠️ **À renseigner pour Forgejo** dans `cronjob-forgejo.yaml` : `RENOVATE_ENDPOINT`
> (URL de ton instance Forgejo, API à la racine — placeholder `https://forgejo.wittnerlab.com/`)
> et `RENOVATE_REPOSITORIES` (placeholder `CHANGE_ME/...`).

## Fichiers

- `cronjob-github.yaml` / `cronjob-forgejo.yaml` — les deux `CronJob` auto-contenus (config par env).
- `renovate-github-env.sealed-secret.yaml` / `renovate-forgejo-env.sealed-secret.yaml` —
  Secrets scellés (committés). **Placeholders à régénérer.**
- `renovate-github-env.secret.yaml` / `renovate-forgejo-env.secret.yaml` — placeholders en
  clair, **gitignored**, pour `kubeseal`.
- `namespace.yaml`, `kustomization.yaml`.

## Tokens (obligatoire avant le premier run)

Pour **chaque** plateforme : remplir le placeholder en clair (clé `RENOVATE_TOKEN`), sceller,
committer le `*.sealed-secret.yaml`. Détails kubeseal :
cf. [`../../infra/sealed-secrets/README.md`](../../infra/sealed-secrets/README.md).

Méthode privilégiée : sceller **directement contre le contrôleur** (accès cluster requis,
**pas de cert local** à gérer). Repli offline si pas d'accès cluster : `kubeseal --fetch-cert
… > pub-cert.pem` puis `--cert pub-cert.pem` (cf. [`../../infra/sealed-secrets/README.md`](../../infra/sealed-secrets/README.md)).

### GitHub — `renovate-github-env` / `RENOVATE_TOKEN`

**Type** : Personal Access Token (PAT). Deux variantes possibles :

| Variante | Où | Scopes / permissions |
|----------|----|----|
| **Fine-grained** (recommandé) | Settings → Developer settings → *Fine-grained tokens* | Repository access = les repos visés ; permissions **Contents: Read & write**, **Pull requests: Read & write**, **Workflows: Read & write**, **Metadata: Read** (auto) |
| **Classic** | Settings → Developer settings → *Tokens (classic)* | scope **`repo`** + scope **`workflow`** |

> `workflow`/`Workflows: RW` n'est nécessaire que si Renovate doit mettre à jour des fichiers
> sous `.github/workflows/`. Sans ça, il échouera sur ces PRs.

(Optionnel) `GITHUB_COM_TOKEN` dans le même secret : un PAT **classic en lecture seule**
(scope `public_repo` ou même aucun scope) sur github.com, juste pour récupérer les
changelogs / release notes des dépendances hébergées sur GitHub.

```bash
# 1. Mettre le PAT dans le placeholder en clair (clé RENOVATE_TOKEN) — fichier gitignored :
#    $EDITOR neltharion/apps/renovate/renovate-github-env.secret.yaml

# 2. Sceller directement contre le contrôleur (pas de cert local) :
kubeseal --controller-name=sealed-secrets --controller-namespace=sealed-secrets --format yaml \
  < neltharion/apps/renovate/renovate-github-env.secret.yaml \
  > neltharion/apps/renovate/renovate-github-env.sealed-secret.yaml

# 3. Committer le sealed-secret (le .secret.yaml en clair reste gitignored) :
git add neltharion/apps/renovate/renovate-github-env.sealed-secret.yaml
```

### Forgejo — `renovate-forgejo-env` / `RENOVATE_TOKEN`

**Type** : token d'accès Forgejo (*Settings → Applications → Generate New Token*) du compte
bot/technique. Sélectionner les scopes :

| Scope | Niveau |
|-------|--------|
| `repository` | Read and Write |
| `issue`      | Read and Write (PRs/commentaires) |
| `user`       | Read |

> Le token doit appartenir à un compte ayant accès **en écriture** aux repos listés dans
> `RENOVATE_REPOSITORIES` (pour pousser les branches et ouvrir les PRs).

```bash
# 1. Mettre le token Forgejo dans le placeholder en clair (clé RENOVATE_TOKEN) — gitignored :
#    $EDITOR neltharion/apps/renovate/renovate-forgejo-env.secret.yaml

# 2. Sceller directement contre le contrôleur (pas de cert local) :
kubeseal --controller-name=sealed-secrets --controller-namespace=sealed-secrets --format yaml \
  < neltharion/apps/renovate/renovate-forgejo-env.secret.yaml \
  > neltharion/apps/renovate/renovate-forgejo-env.sealed-secret.yaml

# 3. Committer le sealed-secret (le .secret.yaml en clair reste gitignored) :
git add neltharion/apps/renovate/renovate-forgejo-env.sealed-secret.yaml
```

Push les `*.sealed-secret.yaml` → Argo sync → le controller crée les Secrets.

> Tant qu'un SealedSecret est le placeholder, le controller échoue à le déchiffrer et les
> pods du CronJob correspondant restent en erreur (`secret "renovate-…-env" not found`).

## Ajouter / retirer un repo

Éditer `RENOVATE_REPOSITORIES` dans le `cronjob-*.yaml` concerné (liste séparée par des
virgules), ou passer `RENOVATE_AUTODISCOVER` à `'true'` pour scanner tous les repos
accessibles par le token.

## Vérification

```bash
# Les CronJobs et leur historique de Jobs
kubectl get cronjob,job -n renovate

# Déclencher un run manuel (par plateforme)
kubectl create job -n renovate --from=cronjob/renovate-github  renovate-github-manual
kubectl create job -n renovate --from=cronjob/renovate-forgejo renovate-forgejo-manual

# Logs du dernier run
kubectl logs -n renovate -l job-name --tail=200 -f
```
