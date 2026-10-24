# Arborescence

```
components/
  cert-manager/
    values.yaml                  # values Helm communes
    manifests/                   # base kustomize commune
clusters/
  bleu-malygos/
    apps.app.yaml                # app-of-apps du cluster (*.app.yaml du dossier)
    argocd/                      # manifests/ : install, secrets de cluster, accès GitHub
    cert-manager/
      cert-manager.app.yaml      # Application ArgoCD
      values.yaml                # surcharge (si besoin)
      manifests/                 # overlay (si besoin)
  bleu-kalecgos/
    apps.app.yaml
    cert-manager/
    <app>/
doc/
script/
```

Un dossier par composant et par cluster. Pas de sous-niveau.

## Surcharger le commun

**Values Helm** : `valueFiles` dans l'ordre, le dernier gagne.

| Cas | `valueFiles` |
|---|---|
| Commun seul | `components/<comp>/values.yaml` |
| Commun + surcharge | commun, puis `clusters/<nom>/<comp>/values.yaml` |
| Spécifique seul | `clusters/<nom>/<comp>/values.yaml` |

- Maps : fusionnées.
- Listes : **remplacées en entier**.

**Manifests** : base kustomize + overlay.

| Cas | `path` de l'Application |
|---|---|
| Commun seul | `components/<comp>/manifests` |
| Commun + surcharge | `clusters/<nom>/<comp>/manifests` (inclut la base, ajoute des patches) |
| Spécifique seul | `clusters/<nom>/<comp>/manifests` |

```yaml
# clusters/<nom>/<comp>/manifests/kustomization.yaml
resources:
  - ../../../../components/<comp>/manifests
patches:
  - target:            # toujours explicite
      kind: Deployment
      name: <nom>
    patch: |
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: <nom>
      spec:
        replicas: 2
```

## Règle

Le commun ne contient que ce qui vaut pour **tous** les clusters qui l'utilisent. Si un cluster doit défaire une valeur, elle va dans les surcharges.

## Nommage

- Application : `<comp>-<cluster-court>` → `openbao-malygos`, `cert-manager-kalecgos`.
- Label `layer` sur chaque Application (filtre « Labels » de l'UI, `-l layer=…`) :

  | `layer` | Quoi |
  |---|---|
  | `boot` | posé à la main au bootstrap puis repris par ArgoCD (`doc/bootstrap/`), app-of-apps comprises |
  | `infra` | plateforme déployée par ArgoCD : stockage, certificats, secrets, supervision, Gateway |
  | `apps` | workloads |

- Fichiers suivis par Renovate : `*.app.yaml`, dossiers `manifests/`.
