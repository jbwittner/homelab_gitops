# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Objet

Dépôt GitOps pour un parc Kubernetes **multi-cluster**, réconcilié par **ArgoCD** depuis `main`. Le dépôt est en reconstruction : l'ancienne arborescence a été archivée et la nouvelle structure n'est pas encore posée. Aucun outil de build, lint ou test n'est versionné.

## `archive/` : à ignorer

Ne pas lire, ne pas modifier, ne pas s'en servir comme modèle ni comme référence. Contenu obsolète conservé pour mémoire. Renovate l'exclut déjà (`ignorePaths`).

## Règles GitOps

- Tout changement de cluster passe par un commit + la réconciliation ArgoCD. Pas de `kubectl apply`/`create`/`patch` impératif pour pousser de la donnée.
- Secrets : uniquement en SealedSecrets. Ne jamais committer ce que `.gitignore` exclut : `*.secret.yaml` (secret en clair avant scellage), `pub-cert.pem`, `*sealed-secrets-key*.yaml`, `*-backup.yaml`, `argocd-deploy-key*`, `.env`.
- Plusieurs clusters : vérifier le contexte `kubectl` courant avant toute commande, même en lecture.
- Scripts utilitaires (`.sh`) : dans `script/` à la racine, jamais à côté du composant.

## Conventions imposées par `renovate.json`

Seul contrat structurel actif du dépôt ; nommer les fichiers en conséquence pour que Renovate les suive :

- Applications ArgoCD : `*.app.yaml` / `*.appset.yaml`.
- Manifestes Kubernetes bruts : sous un dossier `manifests/`.
- Manifestes upstream référencés dans un `kustomization.yaml` : épingler par URL taguée, `https://raw.githubusercontent.com/<org>/<repo>/refs/tags/<tag>/…` ou `https://github.com/<org>/<repo>/releases/download/<tag>/…` (custom manager regex, source `github-releases`).
- Tags d'image en dur dans les manifestes/compose, jamais dans un `.env` (Renovate ne le lit pas).
- Politique : une release doit avoir 7 jours (`minimumReleaseAge`) ; automerge des pin/patch/minor ; Argo CD est self-managed → merge manuel quel que soit le type d'update.

Les descriptions de `renovate.json` mentionnent encore les arbres `k8s/` (ArgoCD), `docker/` (Komodo) et `doc/` : ils n'existent plus hors `archive/`.

## Workflow Git

Commits directs sur `main`. Un miroir push Forgejo → GitHub part à chaque commit.
