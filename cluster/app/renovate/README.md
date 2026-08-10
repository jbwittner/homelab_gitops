# renovate

## Rôle

Mises à jour de dépendances automatisées via [Renovate](https://docs.renovatebot.com/) en mode
self-hosted. Un `CronJob` **quotidien** lance le bot sur les dépôts GitHub ciblés et ouvre des PR
de bump. Aucune exposition réseau (job batch, pas de service).

Le délai avant qu'un bump soit proposé ne vient **pas** de la cadence du cron mais de
`minimumReleaseAge` (7 jours) dans le `renovate.json` **à la racine du repo** : une release doit
avoir 7 jours révolus avant qu'une branche ou une PR soit créée.

## Fichiers

- `renovate.app.yaml` — Application (archétype (c), path → `manifests/`)
- `manifests/cron-job.yaml` — `CronJob` quotidien, `concurrencyPolicy: Forbid`,
  `restartPolicy: Never`. Dépôts ciblés en `args`, configuration du bot via `env` + `envFrom`
  (secret `renovate-env`)
- `manifests/namespace.yaml` — ns `renovate` (`sync-wave: -1`)
- `manifests/renovate.sealed.yaml` — SealedSecret `renovate-env` (PAT GitHub)
- `manifests/renovate.secret.yaml` — template en clair, **gitignoré**
- `manifests/kustomization.yaml` — assemblage

## Contraintes

- La politique de mise à jour (cooldown, automerge, managers, chemins ignorés) vit dans
  `renovate.json` **à la racine**, pas ici. Notamment : `internalChecksFilter: strict` est
  load-bearing — sans lui, `ignoreTests: true` rendrait l'automerge immédiat malgré le cooldown.
- **Argo CD n'est jamais automergé** (`packageRules` de `renovate.json`) : il est self-managed,
  un bump raté casse le moteur GitOps lui-même.
- Cilium et les CRDs Gateway API sont proposés indépendamment alors qu'ils sont **couplés** :
  relire la compatibilité avant de merger (cf. [gateway-api](../../infra/gateway-api/README.md)).

## Opérations

### Câblage du secret

Commandes **depuis la racine du repo** ; les `*.secret.yaml` sont gitignorés.

```bash
# 1. Renseigner le template local :
#    cluster/app/renovate/manifests/renovate.secret.yaml
#    → RENOVATE_GITHUB_COM_TOKEN et RENOVATE_TOKEN (PAT GitHub)

# 2. Sceller, puis supprimer le clair
kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
  < cluster/app/renovate/manifests/renovate.secret.yaml \
  > cluster/app/renovate/manifests/renovate.sealed.yaml
rm cluster/app/renovate/manifests/renovate.secret.yaml

# 3. Commit + push (la ligne `- renovate.sealed.yaml` est déjà dans kustomization.yaml).
```

Rotation : régénérer le PAT côté GitHub, re-renseigner le template, re-sceller (étape 2).

### Droits du token

Doc source : [Renovate — platform/github](https://docs.renovatebot.com/modules/platform/github/).
Le token actuel est un **fine-grained PAT** (`github_pat_…`).

**Fine-grained PAT** — permissions à cocher :

| Permission        | Niveau         | Scope                  |
| ----------------- | -------------- | ---------------------- |
| Metadata          | Read-only      | Repository (implicite) |
| Contents          | Read and write | Repository             |
| Commit statuses   | Read and write | Repository             |
| Issues            | Read and write | Repository             |
| Pull requests     | Read and write | Repository             |
| Workflows         | Read and write | Repository             |
| Dependabot alerts | Read-only      | Repository             |
| Members           | Read-only      | Organization (si org)  |

**Classic PAT** (alternative) : scope `repo` + `workflow` (ce dernier requis pour bumper les
fichiers GitHub Actions).

**GitHub App** (self-hosted, cf. [doc](https://docs.renovatebot.com/modules/platform/github/#running-as-a-github-app)) :
Checks, Commit statuses, Contents, Issues, Pull requests, Workflows en `read+write` ;
Administration, Dependabot alerts, Members, Metadata en `read`.

### Cibles & configuration

Dépôts scannés = `args` du conteneur (`RENOVATE_AUTODISCOVER: "false"` → liste explicite).
Ajouter/retirer un dépôt = éditer `args` dans
`cluster/app/renovate/manifests/cron-job.yaml`, commit + push.

### État & déclenchement manuel

```bash
kubectl -n renovate get cronjob
kubectl -n renovate get jobs,pods
kubectl create job -n renovate --from=cronjob/renovate renovate-manual   # run ad hoc
kubectl -n renovate logs job/renovate-manual -f
```
