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

Traefik tourne en `hostPort` (pas de LoadBalancer). ExternalDNS ne peut pas déduire l'IP depuis le service — il faut la fournir explicitement.

> ⚠️ **La source `traefik-proxy` n'applique PAS `--default-targets`** (seule la source `ingress`
> le fait). Avec des `IngressRoute`, l'IP via `--default-targets` est donc **ignorée** et aucun
> record n'est créé (`No endpoints could be generated from Host …` dans les logs). La cible doit
> être portée par **chaque IngressRoute** :

```yaml
metadata:
  annotations:
    external-dns.alpha.kubernetes.io/hostname: mon-service.wittnerlab.com
    external-dns.alpha.kubernetes.io/target: "5.135.136.115"   # IP du nœud
```

`--default-targets=5.135.136.115` reste dans `values.yaml` comme **filet de sécurité pour
d'éventuels `Ingress` standards** (la source `ingress`, elle, l'honore). Changement d'IP du nœud :
éditer cette ligne **et** l'annotation `target` de chaque IngressRoute.

> 💡 `--policy=upsert-only` ne supprime jamais : un record créé avant un changement de config
> survit même si la source ne le régénère plus — d'où des hosts qui « marchent encore » alors que
> la création de nouveaux hosts est cassée. Pour voir ce qu'external-dns produit réellement :
> `external_dns_source_endpoints_total` (métrique sur `:7979`) ou un run debug en `--dry-run`.

## Vérification

```bash
# Logs ExternalDNS (enregistrements créés / ignorés)
kubectl logs -n external-dns deploy/external-dns

# Enregistrements gérés (ownership via TXT)
kubectl logs -n external-dns deploy/external-dns | grep "CREATE\|UPDATE\|DELETE"
```
