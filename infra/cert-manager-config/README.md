# cert-manager-config

Configuration post-install de cert-manager : `ClusterIssuer` Let's Encrypt (challenge DNS-01 via Cloudflare) et le token API associé.

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
#    infra/cert-manager-config/cloudflare-api-token.secret.yaml

# 2. Sceller avec la clé publique du cluster
kubeseal --cert pub-cert.pem --format yaml \
  < infra/cert-manager-config/cloudflare-api-token.secret.yaml \
  > infra/cert-manager-config/cloudflare-api-token.sealed-secret.yaml
```

Le fichier `cloudflare-api-token.sealed-secret.yaml` est commité ; `cloudflare-api-token.secret.yaml` est gitignored.
