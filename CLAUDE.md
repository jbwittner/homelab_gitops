# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

GitOps repo for the **Neltharion** homelab cluster (Talos / Kubernetes 1.36). It uses the **app-of-apps** pattern: a single root `Application` bootstrapped manually points Argo CD at `definitions/neltharion/`, which recursively discovers every `Application` manifest and owns the full stack from there — including Argo's own config (self-managed).

Source of truth for Argo is **GitHub** (not Forgejo), so the sync loop is: push to `main` → Argo detects change → reconciles cluster.

## Repository layout

```
bootstrap/
  root.yaml               # app-of-apps; kubectl apply -f once, never again

infra/
  argocd/                 # Kustomize bundle used for BOTH bootstrap AND self-management
    kustomization.yaml    # base + patches; some entries commented out until deps are ready
    namespace.yaml

definitions/
  neltharion/
    infra/
      argocd.yaml         # Application: self-management (wave -1, prune: false, ServerSideApply)
    apps/                 # future apps, one .app.yaml per component
```

## Bootstrap procedure (one-time, imperative)

```bash
# 1. Install Argo (server-side is mandatory — CRD annotations exceed client-side limit)
kubectl apply -k infra/argocd --server-side --force-conflicts

# 2. Wait for Argo to be ready
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# 3. Retrieve initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

# 4. Apply the root app-of-apps (triggers everything else)
kubectl apply -f bootstrap/root.yaml
```

After step 4 Argo takes over; all further changes go through Git.

## Adding a new application

1. Create `definitions/neltharion/<category>/<name>.app.yaml` as an `argoproj.io/v1alpha1 Application`.
2. Set `spec.source.path` to wherever the Kustomize/Helm manifests live.
3. Assign a `sync-wave` annotation consistent with the wave table below.
4. Push to `main`; the root Application (recurse: true) picks it up automatically.

## Sync-wave order

| Wave | Components |
|------|-----------|
| -1   | argocd (self-management) |
| 0    | sealed-secrets |
| 1    | local-path-provisioner, cert-manager, ingress-nginx, cert-manager-config |
| 2    | cnpg (operator) |
| 3    | forgejo, authentik |
| 4    | monitoring, postfix |

## Self-management pitfalls

- `prune: false` on the `argocd` Application — never change this; Argo would delete its own components.
- `ServerSideApply=true` must match the manual bootstrap apply — otherwise permanent `OutOfSync`.
- After the first automated sync, repo-server and controller may restart once; this is normal.
- For persistent diffs on webhooks or CRDs, add a targeted `ignoreDifferences` block.

## Deferred activations (uncomment in `infra/argocd/kustomization.yaml` when ready)

- `ingress.yaml` → after cert-manager + ingress-nginx (wave 1)
- `argocd.sealed-secret.yaml` → after sealed-secrets (wave 0) + sealed-secrets controller key reinjection
- SSO Authentik patches (`argocd-cm`, `argocd-rbac-cm`) → after Authentik (wave 3)

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

The cluster runs Kubernetes 1.36 (bleeding-edge). If Argo pods crash-loop with API errors after an Argo upgrade, bump to the latest `v3.3.x` patch (≥ v3.3.3 includes the backport). The `infra/argocd/kustomization.yaml` pins the upstream install manifest via a versioned tag URL — update the tag there.
