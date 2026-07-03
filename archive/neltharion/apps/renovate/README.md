# renovate — neltharion

Renovate **self-hosted (CLI)** exécuté en `CronJob` Kubernetes. Pas de plateforme Mend
hébergée : l'image officielle `renovate/renovate` est lancée périodiquement, scanne les
dépôts configurés et ouvre des PRs de mise à jour.

**Un CronJob, plateforme GitHub** :

| CronJob | Plateforme | Planification | Périmètre | Secret (envFrom) |
|---------|-----------|---------------|-----------|------------------|
| `renovate-github` | `github` | `@daily` (00h UTC) | `jbwittner/homelab_gitops` (`RENOVATE_REPOSITORIES`) | `renovate-github-env` |

Image : `renovate/renovate:43.234.0`. `cronjob-github.yaml` est **auto-contenu** ; toute la
config passe par des **variables d'environnement** ; le token arrive en bloc via
`envFrom: secretRef` sur le Secret scellé.

## Fichiers

- `cronjob-github.yaml` — le `CronJob` auto-contenu (config par env).
- `renovate-github-env.sealed-secret.yaml` — Secret scellé (committé). **Placeholder à régénérer.**
- `renovate-github-env.secret.yaml` — placeholder en clair, **gitignored**, pour `kubeseal`.
- `namespace.yaml`, `kustomization.yaml`.

## Token (obligatoire avant le premier run)

Remplir le placeholder en clair (clé `RENOVATE_TOKEN`), sceller, committer le
`*.sealed-secret.yaml`. Détails kubeseal :
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

> Le token doit appartenir à un compte ayant accès **en écriture** au repo `jbwittner/homelab_gitops`
> (pour pousser les branches et ouvrir les PRs).

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

Push le `*.sealed-secret.yaml` → Argo sync → le controller crée le Secret.

> Tant que le SealedSecret est le placeholder, le controller échoue à le déchiffrer et les
> pods du CronJob restent en erreur (`secret "renovate-github-env" not found`).

## Ajouter / retirer un repo

Éditer `RENOVATE_REPOSITORIES` dans `cronjob-github.yaml` (liste séparée par des virgules),
ou passer `RENOVATE_AUTODISCOVER` à `'true'` pour scanner tous les repos accessibles par le token.

## Vérification

```bash
# Le CronJob et son historique de Jobs
kubectl get cronjob,job -n renovate

# Déclencher un run manuel
kubectl create job -n renovate --from=cronjob/renovate-github renovate-github-manual

# Logs du dernier run
kubectl logs -n renovate -l job-name --tail=200 -f
```
