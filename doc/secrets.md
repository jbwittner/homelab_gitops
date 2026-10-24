# Secrets

## Deux étages

| Étage | Pour quoi | Où |
|---|---|---|
| **SealedSecrets** | boot seulement : GitHub App ArgoCD (`repo-creds`), secret de cluster `bleu-kalecgos` | malygos |
| **OpenBao + External Secrets** | tout le reste | les deux clusters |

Pas de nouveau SealedSecret hors boot.

## Fichiers d'un SealedSecret

| Fichier | Contenu | Commité |
|---|---|---|
| `x.secret.example.yaml` | modèle, valeurs factices, `stringData` | oui |
| `x.secret.yaml` | copie remplie, en clair | non (ignoré) |
| `x.sealed.yaml` | sortie de `kubeseal` | oui |

## OpenBao

- Sur malygos, 1 réplica, stockage raft.
- Un mount d'auth Kubernetes par cluster : `auth/k8s-bleu-malygos`, `auth/k8s-bleu-kalecgos`.
- Accès :
  - malygos → service interne ;
  - kalecgos → `https://bao.lan.wittner.tech`.
- Unseal **manuel** (Shamir) après chaque redémarrage de malygos.
- Sauvegarde : snapshot raft, à la main.

## Ne jamais committer

`*.secret.yaml` · `*.pem` · `*sealed-secrets-key*.yaml` · `*-backup.yaml` · `.env`

Clés d'unseal, token root et clé du controller sealed-secrets : hors dépôt.
