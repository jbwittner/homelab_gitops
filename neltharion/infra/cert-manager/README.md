# cert-manager — neltharion

Configuration de cert-manager sur le cluster : `ClusterIssuer` Let's Encrypt (challenge DNS-01
via Cloudflare) et le token API associé. Les values de la chart (`crds.enabled`) vivent dans
`values.yaml` (ce dossier).

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
