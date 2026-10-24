# Secrets

## Deux étages

| Étage | Pour quoi | Où |
|---|---|---|
| **SealedSecrets** | boot seulement : GitHub App ArgoCD (`repo-creds`), mot de passe admin ArgoCD, secret de cluster `bleu-kalecgos` | malygos |
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
- Structure (KV, auth, policies) en Terraform : dépôt `homelab_terraform`, module `openbao/bleu-malygos`. Valeurs des secrets : `bao kv put`, à la main.
- Secrets rangés en `secret/<comp>/<nom>` (KV v2), partagés entre clusters.
- Un mount d'auth Kubernetes par cluster : `auth/k8s-bleu-malygos`, `auth/k8s-bleu-kalecgos`, rôle `eso` (ServiceAccount `external-secrets/external-secrets`, lecture seule).
  - kalecgos : aucun jeton stocké dans OpenBao ; il valide le jeton d'ESO auprès de l'API de kalecgos, donc le compte d'ESO y porte `system:auth-delegator`.
- Admin : utilisateur `userpass` (policy `admin`) ; token root révoqué, régénérable avec la clé d'unseal.
- Accès :
  - malygos → service interne ;
  - kalecgos → `https://bao.lan.wittner.tech`.
- Unseal **manuel** (Shamir, 1 part) après chaque redémarrage de malygos.
- Sauvegarde : snapshot raft, à la main.
- Procédures : [openbao.md](openbao.md).

## Ne jamais committer

`*.secret.yaml` · `*.pem` · `*sealed-secrets-key*.yaml` · `*-backup.yaml` · `.env`

Clés d'unseal, token root et clé du controller sealed-secrets : hors dépôt.
