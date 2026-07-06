# cert-manager — onyxia

**Deux** `ClusterIssuer` Let's Encrypt (challenge DNS-01 via Cloudflare) et le token API associé.
Les values de la chart (`crds.enabled`) vivent dans `values.yaml` (ce dossier).

| ClusterIssuer | Fichier | ACME | Usage |
|---|---|---|---|
| `letsencrypt-prod` | `cluster-issuer-prod.yaml` | prod | certs trustés (navigateur OK), rate limit strict |
| `letsencrypt-staging` | `cluster-issuer-staging.yaml` | staging | tester la chaîne DNS-01 sans cramer le quota ; certs **non trustés** |

Les deux partagent le **même** token Cloudflare mais des comptes ACME séparés
(`privateKeySecretRef` distincts).

> ⚠️ **État actuel : token PAS encore scellé.** Les deux ClusterIssuers sont déployés mais
> **non fonctionnels** tant que le SealedSecret `cloudflare-api-token` n'existe pas. Suivre la
> procédure ci-dessous, puis décommenter la ligne `cloudflare-api-token.sealed-secret.yaml` dans
> [`kustomization.yaml`](kustomization.yaml).

> **Par-cluster.** Le token est scellé contre la clé du contrôleur sealed-secrets d'**onyxia** :
> le SealedSecret de neltharion NE marche PAS ici — il faut sceller le sien.

## Cloudflare API token

Créer un token **scopé** sur [dash.cloudflare.com/profile/api-tokens](https://dash.cloudflare.com/profile/api-tokens)
avec les permissions minimales :

| Ressource | Permission |
|-----------|-----------|
| Zone → DNS | Edit |
| Zone → Zone | Read |

**Zone Resources** : `Include → Specific zone → <ta-zone>`. Ne pas utiliser la clé API globale.

## Créer le SealedSecret (obligatoire, sur le cluster onyxia)

Prérequis : contrôleur `sealed-secrets` déployé sur onyxia (wave 0) et contexte kubectl pointé
sur onyxia.

```bash
# 1. Remplir le token dans le fichier gitignored (placeholder CHANGE_ME → vrai token)
#    onyxia/infra/cert-manager/cloudflare-api-token.secret.yaml

# 2. Sceller directement contre le contrôleur sealed-secrets d'ONYXIA
kubeseal \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets \
  --format yaml \
  < onyxia/infra/cert-manager/cloudflare-api-token.secret.yaml \
  > onyxia/infra/cert-manager/cloudflare-api-token.sealed-secret.yaml

# 3. Décommenter la ligne cloudflare-api-token.sealed-secret.yaml dans kustomization.yaml

# 4. Committer cloudflare-api-token.sealed-secret.yaml (le .secret.yaml reste gitignored) + push main
```

Argo reconcilie : le SealedSecret est déchiffré en Secret `cloudflare-api-token`, les ClusterIssuers
deviennent `Ready`.

## Tester avec staging puis basculer en prod

Le temps d'itérer sur une conf de cert, pointer `issuerRef.name` sur `letsencrypt-staging` pour ne
pas consommer le rate limit prod, puis repointer sur `letsencrypt-prod`.

```bash
kubectl describe certificate <name> -n <ns>   # Ready=True attendu
kubectl get challenges -A                      # DNS-01 en cours / résolu
```

**Changer l'issuer ne réémet pas** tant que le cert staging est valide — forcer via
`kubectl delete secret <secretName> -n <ns>`.
