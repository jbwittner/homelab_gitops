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
- Namespace : celui de la doc upstream (`kube-system` pour Cilium et sealed-secrets).
- Nom d'Application : `<comp>-<cluster-court>` (`openbao-malygos`, `cert-manager-kalecgos`), label `layer: boot|infra|apps` (voir `doc/arborescence.md`).
- Supervision : chaque composant déclare ses `ServiceMonitor`/`PodMonitor` (option du chart, sinon dans son `manifests/`). CRDs de l'opérateur posées au bootstrap (`prometheus-operator-crds`), pas par kube-prometheus-stack.
- Patch kustomize : toujours avec un bloc `target:` explicite (`kind`, `name`), même quand le patch porte déjà son identité.
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
  - **SealedSecrets** : boot seulement, sur malygos (GitHub App ArgoCD, mot de passe admin ArgoCD, secret de cluster kalecgos). Rien d'autre.
    Trois fichiers côte à côte : `x.secret.example.yaml` (modèle commité, valeurs factices), `x.secret.yaml` (clair, ignoré), `x.sealed.yaml` (commité). Secrets écrits en `stringData`.
  - **OpenBao + External Secrets** : tout le reste.
  - Ne jamais committer ce que `.gitignore` exclut : `*.secret.yaml`, `*.pem`, `*sealed-secrets-key*.yaml`, `*-backup.yaml`, `.env`.
- Exposition : Gateway API de Cilium. DNS AdGuard (192.168.1.2, hors dépôt) : `*.lan.wittner.tech` → 192.168.1.80 (Gateway malygos) ; un hostname servi par kalecgos est relayé par malygos (`clusters/bleu-malygos/external-services`, modèle `homepage.yaml`).

## Conventions imposées par `renovate.json`

- Applications ArgoCD : `*.app.yaml` / `*.appset.yaml`.
- Manifestes Kubernetes bruts : sous un dossier `manifests/`.
- Upstream dans un `kustomization.yaml` : URL taguée, `https://raw.githubusercontent.com/<org>/<repo>/refs/tags/<tag>/…` ou `https://github.com/<org>/<repo>/releases/download/<tag>/…`.
- Version de chart Helm et tags d'image en dur, jamais dans un `.env`.
- Une release doit avoir 7 jours ; automerge des pin/patch/minor ; merge manuel pour Argo CD (`argoproj/argo-cd`) et les CRDs Gateway API (`kubernetes-sigs/gateway-api`, couplées à la version de Cilium) ; `prometheus-operator-crds` et `kube-prometheus-stack` groupés (même opérateur).

Les `description` de `renovate.json` citent encore `k8s/` et `docker/` : périmées.

## Workflow Git

Commits directs sur `main`, poussés sur GitHub (`jbwittner/homelab_gitops` ; ArgoCD le lit via une GitHub App, public ou privé).
