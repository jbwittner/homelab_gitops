# cert-manager — neltharion

Configuration de cert-manager sur le cluster : **deux** `ClusterIssuer` Let's Encrypt (challenge
DNS-01 via Cloudflare) et le token API associé. Les values de la chart (`crds.enabled`) vivent
dans `values.yaml` (ce dossier).

| ClusterIssuer | Fichier | ACME | Usage |
|---|---|---|---|
| `letsencrypt-prod` | `cluster-issuer-prod.yaml` | prod | certs trustés (navigateur OK), rate limit strict |
| `letsencrypt-staging` | `cluster-issuer-staging.yaml` | staging | tester la chaîne DNS-01 sans cramer le quota ; certs **non trustés** |

Les deux partagent le **même** token Cloudflare mais des comptes ACME séparés
(`privateKeySecretRef` distincts : `letsencrypt-prod-account-key` / `letsencrypt-staging-account-key`).

> Le token Cloudflare est scellé pour la clé du contrôleur sealed-secrets de **ce** cluster :
> un autre cluster doit re-sceller le sien.

## Cloudflare API token

Créer un token **scopé** sur [dash.cloudflare.com/profile/api-tokens](https://dash.cloudflare.com/profile/api-tokens) avec les permissions minimales suivantes :

| Ressource | Permission |
|-----------|-----------|
| Zone → DNS | Edit |
| Zone → Zone | Read |

**Zone Resources** : `Include → Specific zone → wittnerlab.com`

Ne pas utiliser la clé API globale (trop de droits).

## Créer le SealedSecret

```bash
# 1. Remplir le token dans le fichier gitignored
#    neltharion/infra/cert-manager/cloudflare-api-token.secret.yaml

# 2. Sceller avec la clé publique du cluster
kubeseal --cert pub-cert.pem --format yaml \
  < neltharion/infra/cert-manager/cloudflare-api-token.secret.yaml \
  > neltharion/infra/cert-manager/cloudflare-api-token.sealed-secret.yaml
```

Le fichier `cloudflare-api-token.sealed-secret.yaml` est commité ; `cloudflare-api-token.secret.yaml` est gitignored.

## Tester avec staging puis basculer en prod

Le temps d'itérer sur une conf de cert (DNS-01, nouveau host/wildcard), pointer d'abord sur
staging pour ne pas consommer le rate limit prod.

```yaml
# Certificate / IngressRoute en test → issuerRef sur staging
issuerRef:
  name: letsencrypt-staging     # au lieu de letsencrypt-prod
  kind: ClusterIssuer
```

Vérifier l'émission :

```bash
kubectl describe certificate <name> -n <ns>   # Ready=True attendu
kubectl get challenges -A                      # DNS-01 en cours / résolu
```

Une fois la chaîne validée, repointer `issuerRef.name` sur `letsencrypt-prod`. **Changer l'issuer
ne réémet pas tant que le cert staging est valide** — forcer la réémission en supprimant le Secret :

```bash
kubectl delete secret <secretName> -n <ns>     # cert-manager réémet depuis prod
```

