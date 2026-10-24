# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Objet

Dépôt GitOps de deux clusters Kubernetes, réconciliés par **un seul ArgoCD** (sur malygos) depuis `main`. Aucun outil de build, lint ou test n'est versionné. Détails dans `doc/`.

| Cluster | Rôle | Nœuds | Contexte kubectl |
|---|---|---|---|
| `bleu-malygos` | infra : ArgoCD, OpenBao, kube-prometheus-stack | 1 (192.168.1.15) | `admin@bleu-malygos` |
| `bleu-kalecgos` | worker : workloads | 3 (192.168.1.11-13) | `admin@bleu-kalecgos` |

Talos 1.13, Kubernetes 1.36, Cilium 1.20 sur les deux.

## Arborescence

```
components/<comp>/        # commun : values.yaml, manifests/ (base kustomize)
clusters/<nom>/<comp>/    # par cluster : <comp>.app.yaml, values.yaml (surcharge), manifests/ (overlay)
doc/                      # docs courtes
script/                   # scripts .sh, jamais à côté d'un composant
```

- Un seul niveau sous `clusters/<nom>/`. Pas d'ApplicationSet.
- Installer un composant : **chart Helm en priorité** (Application chart + `$values`). Kustomize sur URL taguée seulement s'il n'existe pas de chart (CRDs Gateway API) ou par exception décidée (ArgoCD : plus simple à surcharger).
- Nom d'Application : `<cluster-court>-<comp>` (`malygos-openbao`, `kalecgos-cert-manager`).
- Le commun ne contient que ce qui vaut pour **tous** les clusters qui l'utilisent. Voir `doc/arborescence.md`.

## Docs (`doc/`)

- Courtes : tableaux, listes, blocs de commandes ; peu de prose.
- Toute commande s'exécute **depuis la racine du dépôt** (chemins relatifs `components/…`, `clusters/…`).
- Contexte kubectl/helm toujours explicite :
  - commande à jouer sur **les deux clusters** : variables `C`/`CTX` posées en tête de page, puis `--context $CTX`, `clusters/$C/…` ;
  - commande pour **un seul cluster** : valeurs en dur dans la commande (`--context admin@bleu-malygos`, `clusters/bleu-malygos/…`), pas de variable.

## `archive/` : à ignorer

Ne pas lire, ne pas modifier, ne pas s'en servir comme modèle ni comme référence. Renovate l'exclut déjà (`ignorePaths`).

## Règles GitOps

- Tout changement de cluster passe par un commit + la réconciliation ArgoCD. Pas de `kubectl apply`/`create`/`patch` impératif, sauf le boot documenté (ArgoCD, sealed-secrets, `argocd-manager`).
- Deux clusters (et des contextes GKE du travail dans le kubeconfig) : passer `--context` explicitement, même en lecture.
- Secrets :
  - **SealedSecrets** : boot seulement, sur malygos (deploy key Forgejo, secret de cluster kalecgos). Rien d'autre.
  - **OpenBao + External Secrets** : tout le reste.
  - Ne jamais committer ce que `.gitignore` exclut : `*.secret.yaml`, `pub-cert.pem`, `*sealed-secrets-key*.yaml`, `*-backup.yaml`, `argocd-deploy-key*`, `.env`.
- Exposition : Gateway API de Cilium. Tout hostname `*.lan.wittner.tech` doit aussi être déclaré sur le proxy LAN 192.168.1.50 (hors dépôt).

## Conventions imposées par `renovate.json`

- Applications ArgoCD : `*.app.yaml` / `*.appset.yaml`.
- Manifestes Kubernetes bruts : sous un dossier `manifests/`.
- Upstream dans un `kustomization.yaml` : URL taguée, `https://raw.githubusercontent.com/<org>/<repo>/refs/tags/<tag>/…` ou `https://github.com/<org>/<repo>/releases/download/<tag>/…`.
- Version de chart Helm et tags d'image en dur, jamais dans un `.env`.
- Une release doit avoir 7 jours ; automerge des pin/patch/minor ; merge manuel pour Argo CD (`argoproj/argo-cd`) et les CRDs Gateway API (`kubernetes-sigs/gateway-api`, couplées à la version de Cilium).

Les `description` de `renovate.json` citent encore `k8s/` et `docker/` : périmées.

## Workflow Git

Commits directs sur `main`. Un miroir push Forgejo → GitHub part à chaque commit.
