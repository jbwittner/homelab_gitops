# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Documentation upkeep (mandatory)

Toute intervention sur le dépôt **doit** garder la documentation à jour dans le même
changement — la doc fait partie de la définition de « terminé ». Concrètement :

- Si tu ajoutes/supprimes/déplaces un composant, manifeste ou fichier : mets à jour ce
  `CLAUDE.md` (layout, tables sync-wave « deployed » vs « roadmap »), le `README.md` racine,
  et le `README.md` du composant concerné (`<cluster>/<infra|apps>/<composant>/README.md`).
- Quand un élément de la **Roadmap** est déployé, le déplacer dans la table « deployed ».
- Toute référence à un fichier/chemin dans la doc doit pointer vers un fichier qui existe
  réellement. Vérification rapide : `grep` les noms de fichiers cités et confronter à
  `find <cluster> -name '*.yaml'`.
- Ne jamais laisser la doc décrire un état « cible » comme s'il était en place : marquer
  explicitement *implémenté* vs *prévu*.

## What this repo is

GitOps repo for the homelab, designed **multi-cluster** (hub/spoke). A **central Argo CD**
(the *hub*) drives every cluster: the `Application` objects all live on the hub, but their
workloads land on the target cluster (in-cluster for the hub, remote `destination.name:
<cluster>` for spokes). Today the only cluster is **neltharion** (Talos / Kubernetes 1.36,
ingress via **Traefik**), which also acts as the hub.

Deployments are organised per-cluster and **self-contained** — no shared `components/` tree.
Everything for a cluster lives under `<cluster>/{infra,apps}/`, one **self-contained folder
per deployed component** (its presence = the component runs on that cluster) holding the
`<name>.app.yaml` Argo `Application`, its merged Helm `values.yaml`, and the cluster's auxiliary
resources (namespace, sealed-secrets, ClusterIssuer, Kustomize). When a second cluster is added
the whole `<cluster>/` folder is **copied** and adapted — duplication is the accepted trade-off
for a flat, simple layout (no DRY base sharing).

The cluster is deployed through a **3-tier app-of-apps**:

- **Tier 1** — `bootstrap/<cluster>.yaml` (`kubectl apply -f` once on the hub) discovers the two
  part-bootstraps via `directory.recurse + include: '*.bootstrap.yaml'`.
- **Tier 2** — `<cluster>/infra/infra.bootstrap.yaml` and `<cluster>/apps/apps.bootstrap.yaml`,
  each discovering its components via `recurse + include: '*.app.yaml'`.
- **Tier 3** — the component `<name>.app.yaml` files.

The two distinct suffixes (`.bootstrap.yaml` vs `.app.yaml`) are what keep the tiers from
matching each other: the glob is matched against the full relative path with `*` crossing `/`,
so `*.bootstrap.yaml` at tier 1 catches only the two part-bootstraps and `*.app.yaml` at tier 2
catches only the components (everything else — values, kustomizations, sealed-secrets — is left
out of both).

Helm components still use a **native multi-source** Application: the chart source loads one local
`valueFiles` (`$src/<cluster>/infra/<name>/values.yaml`) and a second git source (`ref: src`)
renders the cluster's auxiliary resources (namespace, sealed-secrets) that the chart does not
produce. Single-source is used where there is nothing extra (sealed-secrets, Kustomize apps).

Source of truth for Argo is **GitHub** (not Forgejo), so the sync loop is: push to `main` →
Argo detects change → reconciles cluster.

> **SealedSecrets are per-cluster.** A SealedSecret is encrypted against one cluster's
> controller key, so each cluster runs its own `sealed-secrets` and keeps its own re-sealed
> secrets under `<cluster>/`.

## Repository layout

```
bootstrap/
  neltharion.yaml         # TIER 1 app-of-apps; kubectl apply -f once on the hub
                          # (one <cluster>.yaml per onboarded cluster)

neltharion/               # = hub; in-cluster destination (https://kubernetes.default.svc)
  infra/                  # one SELF-CONTAINED folder per deployed component:
                          #   <name>/<name>.app.yaml + values.yaml (Helm) + aux resources
    infra.bootstrap.yaml  # TIER 2 — discovers infra/*/*.app.yaml
    argocd/               # self-management (wave -1) — app + inlined install + hub overlay
    sealed-secrets/       # app only (Helm, single-source) + operational README
    traefik/              # app + values.yaml + namespace (wave 0)
    cert-manager/         # app + values.yaml + ClusterIssuer + sealed token (wave 1)
    external-dns/         # app + values.yaml + namespace + sealed token (wave 1)
    local-path-provisioner/ # app + Kustomize (upstream manifest pinned + patches) (wave 1) — default StorageClass
  apps/
    apps.bootstrap.yaml   # TIER 2 — discovers apps/*/*.app.yaml
    metrics-server/       # app only (Helm, single-source) (wave 2) — --kubelet-insecure-tls pour Talos
    whoami/               # app + Kustomize (inlined manifests) (wave 3) — incl. PVC local-path (storage smoke test)
    monitoring/           # app + values.yaml + namespace + Grafana IngressRoute/cert (wave 4) — kube-prometheus-stack
```

Each component is one self-contained folder: `<name>.app.yaml` carries the boilerplate
(repoURL, syncPolicy, destination), `values.yaml` (at the folder root) holds that component's
merged Helm values, and the remaining files are the auxiliary Kustomize resources (namespace,
sealed-secrets, ClusterIssuer). The `<name>.app.yaml` and `values.yaml` are ignored both by the
tier-2 glob (`*.app.yaml`) and by the folder's own `kustomization.yaml` (which lists its
resources explicitly). The gitignored `*.secret.yaml` plaintext placeholders (for kubeseal
regeneration) live next to their sealed counterparts under `neltharion/infra/argocd/`.

## Bootstrap procedure (one-time, imperative)

The repo is private. Argo reads it via an **SSH deploy key** stored as a SealedSecret in `neltharion/infra/argocd/argocd-repo.sealed-secret.yaml` — applied in step 1 alongside Argo itself. See `neltharion/infra/argocd/README.md` for how to generate/regenerate it.

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
#    Same Kustomize dir as the self-managed `argocd` Application (neltharion/infra/argocd).
kubectl apply -k neltharion/infra/argocd --server-side --force-conflicts

# 2. Wait for Argo to be ready
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# 3. Retrieve initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

# 4. Apply the cluster's tier-1 app-of-apps (triggers everything else)
#    neltharion.yaml → infra.bootstrap.yaml + apps.bootstrap.yaml → every component *.app.yaml
kubectl apply -f bootstrap/neltharion.yaml
```

After step 4 Argo takes over; all further changes go through Git.

### Onboarding another cluster (spoke)

1. Register the spoke as an Argo **cluster secret** on the hub (sealed), named `<cluster>`.
2. **Copy** the whole `neltharion/` folder to `<cluster>/`, adapt each `<name>.app.yaml`
   (`destination.name: <cluster>`), the two `*.bootstrap.yaml` (name + `path`), `values.yaml`,
   and **re-seal** every secret against the spoke's controller key.
   > ⚠️ Application names are **global** in the hub's `argocd` namespace. `neltharion`,
   > `neltharion-infra`, `neltharion-apps` are cluster-prefixed, but the component names
   > (`argocd`, `traefik`, `cert-manager`, …) are **not** — when copying, prefix their
   > `metadata.name` with the cluster (or rely on `destination.name`) to avoid collisions.
3. `cp bootstrap/neltharion.yaml bootstrap/<cluster>.yaml`, adapt name + `path`, then
   `kubectl apply -f bootstrap/<cluster>.yaml` on the hub.

## Adding a new application

1. Create the component folder `<cluster>/<category>/<name>/` with `<name>.app.yaml`
   (an `argoproj.io/v1alpha1 Application`) inside it. Everything for the component lives here.
2. For Helm components, put the merged Helm values in `<name>/values.yaml` and the auxiliary
   Kustomize resources (namespace, sealed-secrets, issuers) at the folder root with a
   `kustomization.yaml`. For Kustomize apps, put the manifests in the folder and list them in
   `kustomization.yaml`.
3. For Helm components, point `valueFiles` at the single local file
   (`$src/<cluster>/<category>/<name>/values.yaml`) and keep a `ref: src` git source whose
   `path` is the component folder (for the aux resources). Single-source is fine when there is
   nothing extra (sealed-secrets, plain Kustomize apps).
4. Assign a `sync-wave` annotation consistent with the wave table below.
5. Push to `main`; the part's tier-2 bootstrap (recurse + `include: '*.app.yaml'`) picks it up.

## Sync-wave order (deployed)

| Wave | Components |
|------|-----------|
| -1   | argocd (self-management) |
| 0    | sealed-secrets, traefik |
| 1    | cert-manager (+ ClusterIssuer overlay), external-dns, local-path-provisioner (default StorageClass) |
| 2    | metrics-server |
| 3    | whoami (test app) |
| 4    | monitoring (kube-prometheus-stack: Prometheus + Grafana + Alertmanager + node-exporter + kube-state-metrics) |

## Roadmap / planned (not yet in the repo)

Not deployed — keep this separate from the deployed table above. Assign waves when added:

| Wave | Components |
|------|-----------|
| 2    | cnpg (operator) |
| 3    | forgejo, authentik (+ Argo SSO patches) |
| 4    | postfix |

## Self-management pitfalls

- `prune: false` on the `argocd` Application — never change this; Argo would delete its own components.
- `ServerSideApply=true` must match the manual bootstrap apply — otherwise permanent `OutOfSync`.
- After the first automated sync, repo-server and controller may restart once; this is normal.
- For persistent diffs on webhooks or CRDs, add a targeted `ignoreDifferences` block.

## Planned Argo activations

The Argo UI is already exposed via `argocd-ingress-route.yaml` + `argocd-certificate.yaml`
(both active in `neltharion/infra/argocd/kustomization.yaml`). Still on the roadmap:

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

The cluster runs Kubernetes 1.36 (bleeding-edge). The `neltharion/infra/argocd/kustomization.yaml` pins the upstream install manifest via a versioned tag URL (currently `v3.4.3`). If Argo pods crash-loop with API errors after an upgrade, bump to the latest stable Argo patch — update the tag there.
