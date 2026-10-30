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
- Un secret par composant, `secret/<comp>` (KV v2), un champ par valeur nommé selon son sens (`secret/grafana` → `admin_password`, `secret/cert-manager` → `cloudflare_secret`) ; partagés entre clusters.
  - Créer : `bao kv put` ; ajouter ou changer un champ d'un secret existant : `bao kv patch` (`put` remplace tout le secret).
- Un mount d'auth Kubernetes par cluster : `auth/k8s-bleu-malygos`, `auth/k8s-bleu-kalecgos`, rôle `eso` (ServiceAccount `external-secrets/external-secrets`, lecture seule).
  - kalecgos : aucun jeton stocké dans OpenBao ; il valide le jeton d'ESO auprès de l'API de kalecgos, donc le compte d'ESO y porte `system:auth-delegator`.
- Admin : OIDC par Authelia (groupe `admins` → policy `admin`), utilisateur `userpass` en secours ; token root révoqué, régénérable avec la clé d'unseal.
- Accès :
  - malygos → service interne ;
  - kalecgos → `https://openbao.lan.wittner.tech`.
- Unseal **manuel** (Shamir, 1 part) après chaque redémarrage de malygos.
- Sauvegarde : snapshot raft quotidien par Velero ([sauvegardes](sauvegardes.md)).
- Procédures : [openbao.md](openbao.md).

## External Secrets

| Cluster | `ClusterSecretStore` `openbao` | Auth |
|---|---|---|
| malygos | `http://openbao-active.openbao.svc:8200` | `auth/k8s-bleu-malygos`, rôle `eso` |
| kalecgos | `https://openbao.lan.wittner.tech` (Gateway de malygos) | `auth/k8s-bleu-kalecgos`, rôle `eso` ; compte d'ESO lié à `system:auth-delegator` |

Lire un champ de `secret/<comp>` :

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
        key: <comp>        # sans secret/ ni data/
        property: <champ>  # admin_password, cloudflare_secret…
```

## Images privées ghcr.io

kalecgos : `ClusterExternalSecret` `ghcr-pull` (`clusters/bleu-kalecgos/external-secrets/manifests/ghcr-pull.yaml`) → Secret `ghcr-pull` dans chaque namespace labellisé `ghcr-pull: enabled`. Pod : `imagePullSecrets: [{name: ghcr-pull}]`.

Jeton : PAT GitHub classic, scope `read:packages` seul (tous les packages du compte ; GitHub App et PAT fine-grained ne lisent pas ghcr) :

```sh
export BAO_ADDR=https://openbao.lan.wittner.tech
bao login -method=oidc
read -rs GHCR_TOKEN   # coller le PAT, non affiché
bao kv put secret/ghcr token="$GHCR_TOKEN"; unset GHCR_TOKEN
```

## Ne jamais committer

`*.secret.yaml` · `*.pem` · `*sealed-secrets-key*.yaml` · `*-backup.yaml` · `.env`

Clés d'unseal, token root et clé du controller sealed-secrets : hors dépôt.
