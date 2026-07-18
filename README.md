# homelab_gitops

Dépôt GitOps du homelab. Un cluster actif : **bleu-kalecgos** (Talos mono-nœud `vert-eranikus`),
piloté intégralement par **ArgoCD** en app-of-apps.

> **Règle non négociable** : aucune donnée n'est poussée au cluster hors GitOps —
> [doc/regles-gitops.md](doc/regles-gitops.md).

## Structure

```
homelab_gitops/
├── bleu-kalecgos/    # cluster actif (app-of-apps) — infra/ + app/
├── doc/              # règles, conventions, runbook
├── .claude/skills/   # skills projet
└── archive/          # anciens clusters, hors périmètre actif
```

## Clusters

- [bleu-kalecgos](bleu-kalecgos/README.md) — cluster actif (liste des composants déployés)

## Documentation

- [doc/regles-gitops.md](doc/regles-gitops.md) — règles GitOps (kubectl, secrets, SealedSecrets)
- [doc/conventions.md](doc/conventions.md) — layout des composants, naming, archétypes, sync-waves, pattern helm-values
- [doc/reseau.md](doc/reseau.md) — exposition réseau (Gateway API, `shared-gw`, TLS)
- [doc/runbook-bootstrap-kalecgos.md](doc/runbook-bootstrap-kalecgos.md) — bootstrap / disaster recovery complet
- [.claude/skills/README.md](.claude/skills/README.md) — skills projet (dont vérification des règles)

## Bootstrap / disaster recovery

Procédure complète dans le [runbook](doc/runbook-bootstrap-kalecgos.md). Tout converge par
sync-waves après le bootstrap d'ArgoCD ([bleu-kalecgos/infra/argocd/README.md](bleu-kalecgos/infra/argocd/README.md)).
