# external-dns — neltharion

Synchronisation automatique des enregistrements DNS Cloudflare à partir des ressources Kubernetes (Ingress, Traefik IngressRoute).

- **Toute la config** vit dans `values.yaml` (ce dossier) : `provider`/`env`/`sources`,
  `domainFilters: wittnerlab.com`, `txtOwnerId: neltharion`, et `extraArgs`
  (`--traefik-disable-legacy` + `--default-targets=<IP du nœud>`).
- **Token Cloudflare** : scellé pour CE cluster (re-sceller sur un autre cluster).

## Cloudflare API token

Même périmètre que pour cert-manager :

| Ressource | Permission |
|-----------|-----------|
| Zone → DNS | Edit |
| Zone → Zone | Read |

**Zone Resources** : `Include → Specific zone → wittnerlab.com`

## Créer le SealedSecret

```bash
# 1. Remplir le token dans le fichier gitignored
#    neltharion/infra/external-dns/cloudflare-api-token.secret.yaml

# 2. Sceller avec la clé publique du cluster
kubeseal --cert pub-cert.pem --format yaml \
  < neltharion/infra/external-dns/cloudflare-api-token.secret.yaml \
  > neltharion/infra/external-dns/cloudflare-api-token.sealed-secret.yaml
```

Le fichier `cloudflare-api-token.sealed-secret.yaml` est commité ; `cloudflare-api-token.secret.yaml` est gitignored.

## Homelab hostPort — IP cible

Traefik tourne en `hostPort` (pas de LoadBalancer). ExternalDNS ne peut pas déduire l'IP depuis le service — il faut la fournir explicitement sur chaque IngressRoute :

```yaml
metadata:
  annotations:
    external-dns.alpha.kubernetes.io/hostname: mon-service.wittnerlab.com
    external-dns.alpha.kubernetes.io/target: "<node-public-ip>"
```

Ou via `--default-targets` dans `values.yaml` si tous les services partagent la même IP :

```yaml
extraArgs:
  - --traefik-disable-legacy
  - --default-targets=<node-public-ip>
```

## Vérification

```bash
# Logs ExternalDNS (enregistrements créés / ignorés)
kubectl logs -n external-dns deploy/external-dns

# Enregistrements gérés (ownership via TXT)
kubectl logs -n external-dns deploy/external-dns | grep "CREATE\|UPDATE\|DELETE"
```
