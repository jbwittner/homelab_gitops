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
  - kalecgos → `https://openbao.lan.wittner.tech`.
- Unseal **manuel** (Shamir, 1 part) après chaque redémarrage de malygos.
- Sauvegarde : snapshot raft, à la main.
- Procédures : [openbao.md](openbao.md).

## External Secrets

| Cluster | `ClusterSecretStore` `openbao` | Auth |
|---|---|---|
| malygos | `http://openbao-active.openbao.svc:8200` | `auth/k8s-bleu-malygos`, rôle `eso` |
| kalecgos | `https://openbao.lan.wittner.tech` (après cert-manager + Gateway) | `auth/k8s-bleu-kalecgos`, rôle `eso` ; compte d'ESO lié à `system:auth-delegator` |

Lire un secret `secret/<comp>/<nom>` :

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: <nom>
  namespace: <ns>
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: openbao
  refreshInterval: 1h
  target:
    name: <nom>          # Secret Kubernetes créé par ESO
  data:
    - secretKey: <clé dans le Secret>
      remoteRef:
        key: <comp>/<nom>  # sans secret/ ni data/
        property: <champ du secret OpenBao>
```

## Ne jamais committer

`*.secret.yaml` · `*.pem` · `*sealed-secrets-key*.yaml` · `*-backup.yaml` · `.env`

Clés d'unseal, token root et clé du controller sealed-secrets : hors dépôt.
