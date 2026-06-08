# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Documentation upkeep (mandatory)

Toute intervention sur le dépôt **doit** garder la documentation à jour dans le même
changement — la doc fait partie de la définition de « terminé ». Concrètement :

- Si tu ajoutes/supprimes/déplaces un composant, manifeste ou fichier : mets à jour ce
  `CLAUDE.md` (layout, tables sync-wave « deployed » vs « roadmap »), le `README.md` racine,
  et le `README.md` du composant concerné (`infra/<composant>/README.md`).
- Quand un élément de la **Roadmap** est déployé, le déplacer dans la table « deployed ».
- Toute référence à un fichier/chemin dans la doc doit pointer vers un fichier qui existe
  réellement. Vérification rapide : `grep` les noms de fichiers cités et confronter à
  `find definitions -name '*.yaml'` / `ls infra/argocd`.
- Ne jamais laisser la doc décrire un état « cible » comme s'il était en place : marquer
  explicitement *implémenté* vs *prévu*.

## What this repo is

GitOps repo for the **Neltharion** homelab cluster (Talos / Kubernetes 1.36, ingress via **Traefik**). It uses the **app-of-apps** pattern: two root `Application`s bootstrapped manually point Argo CD at `definitions/neltharion/`, which recursively discovers every `Application` manifest and owns the full stack from there — including Argo's own config (self-managed).

Source of truth for Argo is **GitHub** (not Forgejo), so the sync loop is: push to `main` → Argo detects change → reconciles cluster.

## Repository layout

```
bootstrap/
  root-infra.yaml         # app-of-apps for infra; kubectl apply -f once, never again
  root-apps.yaml          # app-of-apps for apps;  kubectl apply -f once, never again

infra/                    # deployed content (Kustomize / Helm values) — Argo reads these
  argocd/                 # Kustomize bundle used for BOTH bootstrap AND self-management
    kustomization.yaml    # base (pinned upstream install.yaml) + cmd-params patch
    namespace.yaml
    argocd-certificate.yaml        # cert-manager Certificate for the Argo UI
    argocd-ingress-route.yaml      # Traefik IngressRoute for the Argo UI
    argocd-repo.secret.yaml        # gitignored — SSH private key placeholder
    argocd-repo.sealed-secret.yaml # committed — sealed repo credentials for Argo
    argocd-webhook.sealed-secret.yaml # committed — sealed GitHub webhook secret
  sealed-secrets/         # operational README only (controller is Helm-deployed, see definitions)
  traefik/                # namespace + values.yaml for the Traefik chart
  cert-manager-config/    # ClusterIssuer (Let's Encrypt DNS-01) + sealed Cloudflare token
  external-dns/           # namespace + values.yaml + sealed Cloudflare token

definitions/
  neltharion/
    infra/                # one Argo Application per infra component
      argocd.yaml         # self-management (wave -1, prune: false, ServerSideApply)
      sealed-secrets.yaml # sealed-secrets controller, Helm (wave 0)
      traefik.yaml        # Traefik, Helm + overlay infra/traefik (wave 0)
      cert-manager.yaml   # cert-manager, Helm + overlay infra/cert-manager-config (wave 1)
      external-dns.yaml   # external-dns, Helm + overlay infra/external-dns (wave 1)
    apps/                 # business apps, one .yaml per component
      whoami.app.yaml     # test app (wave 3)

apps/
  whoami/                 # test app manifests (Deployment, Service, Certificate, IngressRoute)
```

## Bootstrap procedure (one-time, imperative)

The repo is private. Argo reads it via an **SSH deploy key** stored as a SealedSecret in `infra/argocd/argocd-repo.sealed-secret.yaml` — applied in step 1 alongside Argo itself. See `infra/argocd/README.md` for how to generate/regenerate it.

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
kubectl apply -k infra/argocd --server-side --force-conflicts

# 2. Wait for Argo to be ready
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# 3. Retrieve initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

# 4. Apply the two app-of-apps roots (triggers everything else)
kubectl apply -f bootstrap/root-infra.yaml -f bootstrap/root-apps.yaml
```

After step 4 Argo takes over; all further changes go through Git.

## Adding a new application

1. Create `definitions/neltharion/<category>/<name>.app.yaml` as an `argoproj.io/v1alpha1 Application`.
2. Set `spec.source.path` to wherever the Kustomize/Helm manifests live.
3. Assign a `sync-wave` annotation consistent with the wave table below.
4. Push to `main`; the root Application (recurse: true) picks it up automatically.

## Sync-wave order (deployed)

| Wave | Components |
|------|-----------|
| -1   | argocd (self-management) |
| 0    | sealed-secrets, traefik |
| 1    | cert-manager (+ cert-manager-config), external-dns |
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
(both active in `infra/argocd/kustomization.yaml`). Still on the roadmap:

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

The cluster runs Kubernetes 1.36 (bleeding-edge). The `infra/argocd/kustomization.yaml` pins the upstream install manifest via a versioned tag URL (currently `v3.4.3`). If Argo pods crash-loop with API errors after an upgrade, bump to the latest stable Argo patch — update the tag there.
