# Règles GitOps — NON négociables

## Aucune donnée hors GitOps

**Interdit de pousser des données au cluster hors GitOps.**

- Toute ressource (Application, Deployment, Service, Gateway, HTTPRoute, ConfigMap, Secret,
  cert TLS…) vit dans **Git** et est appliquée par **ArgoCD**. Jamais de `kubectl apply/create`
  impératif.
- Une modif = éditer le manifeste, commit, push. ArgoCD (self-heal) converge. Pas de dérive
  manuelle.

## Périmètre autorisé de `kubectl`

`kubectl` en écriture est réservé à **deux cas**, rien d'autre :

1. **Bootstrap initial d'ArgoCD** — cf. [runbook](runbook-bootstrap-kalecgos.md) et
   [`bleu-kalecgos/infra/argocd/README.md`](../bleu-kalecgos/infra/argocd/README.md).
2. **Debug read-only** — `get`, `describe`, `logs`, `diff`.

## Secrets

- **Jamais** de `kubectl create secret`, jamais de Secret en clair dans Git.
- Canal unique : **SealedSecrets** — chiffrer avec `kubeseal`, committer le `SealedSecret`,
  le contrôleur déchiffre dans le cluster.
- Procédure : [`bleu-kalecgos/infra/sealed-secrets/README.md`](../bleu-kalecgos/infra/sealed-secrets/README.md).

## Dépannage impératif

Si un état a été créé impérativement en dépannage (ex. secret self-signed temporaire), il doit
être **remplacé par son équivalent GitOps** (SealedSecret, manifeste committé) puis supprimé du
cluster. Aucun état impératif ne doit survivre.
