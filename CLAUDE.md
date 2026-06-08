# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Documentation upkeep (mandatory)

Toute intervention sur le dépôt **doit** garder la documentation à jour dans le même
changement — la doc fait partie de la définition de « terminé ». Concrètement :

- Si tu ajoutes/supprimes/déplaces un composant, manifeste ou fichier : mets à jour ce
  `CLAUDE.md` (layout, tables sync-wave « deployed » vs « roadmap »), le `README.md` racine,
  et le `README.md` du composant concerné (`components/<infra|apps>/<composant>/README.md`
  pour la partie partagée, `clusters/<cluster>/...` pour le spécifique-cluster).
- Quand un élément de la **Roadmap** est déployé, le déplacer dans la table « deployed ».
- Toute référence à un fichier/chemin dans la doc doit pointer vers un fichier qui existe
  réellement. Vérification rapide : `grep` les noms de fichiers cités et confronter à
  `find clusters components -name '*.yaml'`.
- Ne jamais laisser la doc décrire un état « cible » comme s'il était en place : marquer
  explicitement *implémenté* vs *prévu*.

## What this repo is

GitOps repo for the homelab, designed **multi-cluster** (hub/spoke). A **central Argo CD**
(the *hub*) drives every cluster: the `Application` objects all live on the hub, but their
workloads land on the target cluster (in-cluster for the hub, remote `destination.name:
<cluster>` for spokes). Today the only cluster is **neltharion** (Talos / Kubernetes 1.36,
ingress via **Traefik**), which also acts as the hub.

Deployments follow a two-axis convention:

- **`components/{infra,apps}/<name>/`** — cluster-agnostic shared bases (common Helm values,
  Kustomize bases).
- **`clusters/<cluster>/{infra,apps}/`** — per-cluster layer: one `<name>.app.yaml` Argo
  `Application` **per deployed component** (its presence = the component runs on that cluster)
  + the cluster-specific overrides (values, namespaces, sealed-secrets, Kustomize patches).

Helm components use a **native multi-source** Application: the chart source layers
`valueFiles` (`$src/components/...values-common.yaml` then `$src/clusters/...values.yaml`,
Helm merges in order), and a second git source (`ref: src`) renders the cluster's auxiliary
resources (namespace, sealed-secrets). One app-of-apps **per cluster** (`bootstrap/root-<cluster>.yaml`)
discovers that cluster's Applications via `directory.recurse + include: '*.app.yaml'` (the
glob, matched against the full relative path with `*` crossing `/`, keeps everything that is
not an `*.app.yaml` — values, kustomizations, sealed-secrets — out of the root).

Source of truth for Argo is **GitHub** (not Forgejo), so the sync loop is: push to `main` →
Argo detects change → reconciles cluster.

> **SealedSecrets are per-cluster.** A SealedSecret is encrypted against one cluster's
> controller key, so each cluster runs its own `sealed-secrets` and keeps its own re-sealed
> secrets under `clusters/<cluster>/`.

## Repository layout

```
bootstrap/
  root-neltharion.yaml    # app-of-apps for the neltharion cluster; kubectl apply -f once on the hub
                          # (one root-<cluster>.yaml per onboarded cluster)

components/               # SHARED bases, cluster-agnostic (mirror of infra/apps)
  infra/
    traefik/values-common.yaml        # common Traefik Helm values
    cert-manager/values-common.yaml   # common cert-manager values (crds.enabled)
    external-dns/values-common.yaml   # common external-dns values (provider/env/sources)
    argocd/base/                      # shared Argo bundle: pinned install.yaml + cmd-params patch
    sealed-secrets/                   # operational README only (controller is Helm-deployed)
  apps/
    whoami/base/                      # Kustomize base (Deployment, Service, Certificate, IngressRoute)

clusters/
  neltharion/             # = hub; in-cluster destination (https://kubernetes.default.svc)
    infra/                # one SELF-CONTAINED folder per deployed component:
                          #   <name>/<name>.app.yaml + values/values.yaml (Helm override)
                          #   + aux resources (namespace, sealed-secrets, kustomization)
      argocd/             # self-management (wave -1) — app + hub overlay (UI Cert/IngressRoute, sealed secrets)
      sealed-secrets/     # app only (Helm, single-source, no override)
      traefik/            # app + values/ + namespace (wave 0)
      cert-manager/       # app + values/ + ClusterIssuer + sealed token (wave 1)
      external-dns/       # app + values/ + namespace + sealed token (wave 1)
    apps/
      whoami/             # app + Kustomize overlay → components/apps/whoami/base (wave 3)
```

Each component is one self-contained folder: `<name>.app.yaml` carries the boilerplate
(repoURL, syncPolicy, destination), `values/` holds that cluster's Helm override(s), and the
remaining files are the cluster's auxiliary Kustomize resources (namespace, sealed-secrets,
ClusterIssuer). The `<name>.app.yaml` and `values/` are ignored both by the root glob and by
the folder's own `kustomization.yaml`. The gitignored `*.secret.yaml` plaintext placeholders
(for kubeseal regeneration) live next to their sealed counterparts under
`clusters/neltharion/infra/argocd/`.

## Bootstrap procedure (one-time, imperative)

The repo is private. Argo reads it via an **SSH deploy key** stored as a SealedSecret in `clusters/neltharion/infra/argocd/argocd-repo.sealed-secret.yaml` — applied in step 1 alongside Argo itself. See `clusters/neltharion/infra/argocd/README.md` for how to generate/regenerate it.

> **Ordre du bootstrap (dépendance circulaire).** La repo-cred est *scellée* ; seul le contrôleur
> sealed-secrets peut la déchiffrer. Ce contrôleur est normalement déployé par Argo en wave 0, qui a
> elle-même besoin de la repo-cred pour cloner le repo. On brise le cycle en **installant
> sealed-secrets manuellement en step 0**, avec les mêmes nom/namespace/version que l'Application
> wave 0 (Argo l'adopte ensuite). La numérotation des sync-waves ne garantit pas cet ordre — c'est
> ce geste manuel qui le fait.

```bash
# 0. Install the sealed-secrets controller FIRST so the sealed repo credential can be decrypted
#    (same name/namespace/version as the wave-0 Application → Argo adopts it without churn)
helm install sealed-secrets sealed-secrets \
  --repo https://bitnami-labs.github.io/sealed-secrets \
  --version 2.18.6 \
  --namespace sealed-secrets --create-namespace
kubectl wait --for=condition=available --timeout=120s deployment/sealed-secrets -n sealed-secrets

# 1. Install Argo + sealed repo credentials (server-side mandatory — CRD annotations exceed client-side limit)
#    Same Kustomize dir as the self-managed `argocd` Application (clusters/neltharion/infra/argocd).
kubectl apply -k clusters/neltharion/infra/argocd --server-side --force-conflicts

# 2. Wait for Argo to be ready
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# 3. Retrieve initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

# 4. Apply the cluster's app-of-apps root (triggers everything else)
kubectl apply -f bootstrap/root-neltharion.yaml
```

After step 4 Argo takes over; all further changes go through Git.

### Onboarding another cluster (spoke)

1. Register the spoke as an Argo **cluster secret** on the hub (sealed), named `<cluster>`.
2. Create `clusters/<cluster>/{infra,apps}/` with the `<name>.app.yaml` you want there
   (each with `destination.name: <cluster>`), their overlays/values, and **re-sealed** secrets.
3. `kubectl apply -f bootstrap/root-<cluster>.yaml` on the hub.

## Adding a new application

1. Create the component folder `clusters/<cluster>/<category>/<name>/` with
   `<name>.app.yaml` (an `argoproj.io/v1alpha1 Application`) inside it.
2. Put shared bits in `components/<category>/<name>/` (Helm `values-common.yaml` and/or a
   Kustomize `base/`); put cluster-specific bits in the same component folder: Helm overrides
   in `values/values.yaml`, auxiliary Kustomize resources (namespace, sealed-secrets) at the
   folder root with a `kustomization.yaml`.
3. For Helm components, layer values via `valueFiles` (`$src/components/...values-common.yaml`
   then `$src/clusters/.../<name>/values/values.yaml`) with a `ref: src` git source whose
   `path` is the component folder; for Kustomize apps, reference the base from the cluster
   overlay. Single-source is fine when there is no customization (sealed-secrets).
4. Assign a `sync-wave` annotation consistent with the wave table below.
5. Push to `main`; the cluster's root Application (recurse + `include: '*.app.yaml'`) picks it up.

## Sync-wave order (deployed)

| Wave | Components |
|------|-----------|
| -1   | argocd (self-management) |
| 0    | sealed-secrets, traefik |
| 1    | cert-manager (+ ClusterIssuer overlay), external-dns |
| 3    | whoami (test app) |

## Roadmap / planned (not yet in the repo)

Not deployed — keep this separate from the deployed table above. Assign waves when added:

| Wave | Components |
|------|-----------|
| 1    | local-path-provisioner |
| 2    | cnpg (operator) |
| 3    | forgejo, authentik (+ Argo SSO patches) |
| 4    | monitoring, postfix |

## Self-management pitfalls

- `prune: false` on the `argocd` Application — never change this; Argo would delete its own components.
- `ServerSideApply=true` must match the manual bootstrap apply — otherwise permanent `OutOfSync`.
- After the first automated sync, repo-server and controller may restart once; this is normal.
- For persistent diffs on webhooks or CRDs, add a targeted `ignoreDifferences` block.

## Planned Argo activations

The Argo UI is already exposed via `argocd-ingress-route.yaml` + `argocd-certificate.yaml`
(both active in `clusters/neltharion/infra/argocd/kustomization.yaml`). Still on the roadmap:

- SSO Authentik patches (`argocd-cm`, `argocd-rbac-cm`) → add after Authentik lands (wave 3).

Note: `argocd-repo.sealed-secret.yaml` and `argocd-webhook.sealed-secret.yaml` are active from bootstrap.

## Useful commands

```bash
# Check application status
kubectl get applications -n argocd
argocd app list

# Manual resync
argocd app sync <name>

# Diff an app
argocd app diff <name>

# Argo component logs
kubectl logs -n argocd deploy/argocd-repo-server
kubectl logs -n argocd statefulset/argocd-application-controller
```

## K8s 1.36 compatibility note

The cluster runs Kubernetes 1.36 (bleeding-edge). The `components/infra/argocd/base/kustomization.yaml` pins the upstream install manifest via a versioned tag URL (currently `v3.4.3`). If Argo pods crash-loop with API errors after an upgrade, bump to the latest stable Argo patch — update the tag there.
