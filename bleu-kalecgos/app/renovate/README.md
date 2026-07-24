# renovate

## Rôle

Automatisation des mises à jour de dépendances via [Renovate](https://docs.renovatebot.com/)
en mode self-hosted. Un `CronJob` `@hourly` lance le bot Renovate sur les dépôts GitHub ciblés
et ouvre des PR de bump. Aucune exposition réseau (job batch, pas de service).

## Fichiers

- `renovate.app.yaml` — Application ArgoCD (kustomize, `source.path` → `manifests/`).
  `ServerSideApply=true`.
- `manifests/cron-job.yaml` — `CronJob` `@hourly`, `concurrencyPolicy: Forbid`,
  `restartPolicy: Never`. Cible(s) de dépôt en `args`, config bot via `env` + `envFrom`
  (secret `renovate-env`).
- `manifests/namespace.yaml` — namespace `renovate` (`sync-wave: -1`).
- `manifests/renovate.secret.yaml` — **template local gitignoré** (`*.secret.yaml`) portant le
  PAT GitHub (`RENOVATE_GITHUB_COM_TOKEN`). À sceller, ne jamais committer en clair.
- `manifests/kustomization.yaml` — assemblage (namespace + cron-job ; le SealedSecret
  `renovate-env` est à ajouter une fois scellé, cf. Opérations).

## Opérations

### Câblage du secret (depuis la racine du repo ; `*.secret.yaml` gitignoré)

```bash
# 1. Renseigner le template local manifests/renovate.secret.yaml
#    RENOVATE_GITHUB_COM_TOKEN → PAT GitHub (scope repo/PR sur les dépôts ciblés)

# 2. Sceller, puis supprimer le fichier en clair
kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
  < bleu-kalecgos/app/renovate/manifests/renovate.secret.yaml \
  > bleu-kalecgos/app/renovate/manifests/renovate.sealed.yaml
rm bleu-kalecgos/app/renovate/manifests/renovate.secret.yaml

# 3. Ajouter `renovate-env.sealed.yaml` aux resources de manifests/kustomization.yaml,
#    commit + push.
```

Rotation : régénérer le PAT côté GitHub, re-renseigner le template, re-sceller (étape 2).

### Cibles & configuration

Dépôts scannés = `args` du conteneur (`RENOVATE_AUTODISCOVER: "false"` → liste explicite).
Ajouter/retirer un dépôt = éditer `args` dans `manifests/cron-job.yaml`, commit + push.

### État & déclenchement manuel

```bash
kubectl get cronjob -n renovate
kubectl get jobs,pods -n renovate
kubectl create job -n renovate --from=cronjob/renovate renovate-manual   # run ad hoc
kubectl logs -n renovate job/renovate-manual -f
```
