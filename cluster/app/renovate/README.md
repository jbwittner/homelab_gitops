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
- `manifests/renovate.externalsecret.yaml` — `ExternalSecret` `renovate-env` (PAT GitHub), servi par
  [openbao](../../infra/openbao/README.md)
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

Le PAT vit dans openbao — **rien à committer**, l'`ExternalSecret` qui le pointe est déjà dans
le repo. Une seule entrée au coffre alimente les **deux** variables attendues par Renovate
(`RENOVATE_TOKEN` pour la plateforme, `RENOVATE_GITHUB_COM_TOKEN` pour les lookups de releases) :

```bash
kubectl -n openbao exec -ti openbao-0 -- \
  bao kv put kv/homelab/renovate/github token=<PAT GitHub>
```

Rotation : régénérer le PAT côté GitHub, refaire le `bao kv put` — les deux variables suivent.

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
