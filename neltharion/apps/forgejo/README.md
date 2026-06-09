# forgejo — neltharion

Forgejo self-hosted (forge Git) avec base PostgreSQL CloudNativePG.  
URL : **https://forgejo.wittnerlab.com** | SSH Git : **forgejo.wittnerlab.com:2222**

| Paramètre | Valeur |
|-----------|--------|
| Image | `codeberg.org/forgejo/forgejo:15` |
| Namespace | `forgejo` |
| Wave | 3 (après cnpg wave 2) |
| Base de données | CNPG Cluster `forgejo-db` (PostgreSQL 16, 5Gi) |
| Stockage app | PVC `forgejo-data` 50Gi (local-path) |
| HTTP | `forgejo-http` ClusterIP :80→3000 (TLS terminé par Traefik) |
| SSH | `forgejo-ssh` ClusterIP :22→22 (TCP passthrough Traefik entrypoint `ssh` port 2222) |
| Registry packages | activée (`FORGEJO__packages__ENABLED=true`) |
| Quota | activé (`FORGEJO__quota__ENABLED=true`) — seuil par défaut à configurer via admin UI |

## Fichiers

| Fichier | Rôle |
|---------|------|
| `forgejo.app.yaml` | Application Argo CD (Kustomize single-source, wave 3) |
| `kustomization.yaml` | Liste des ressources Kustomize |
| `namespace.yaml` | Namespace `forgejo` |
| `db-cluster.yaml` | Cluster CNPG `forgejo-db` (PostgreSQL, 5Gi) |
| `pvc.yaml` | PVC `forgejo-data` 50Gi (stockage `/data` Forgejo) |
| `forgejo-admin.secret.yaml` | **Gitignored** — placeholder en clair pour kubeseal |
| `forgejo-admin.sealed-secret.yaml` | Secret admin scellé (username / password / email) |
| `deployment.yaml` | Deployment Forgejo (image v15, env vars DB depuis CNPG) |
| `service-http.yaml` | Service HTTP :80→3000 (Traefik) |
| `service-ssh.yaml` | Service SSH :22→22 (IngressRouteTCP) |
| `certificate.yaml` | Cert Let's Encrypt via `letsencrypt-prod` ClusterIssuer |
| `ingress-route.yaml` | Traefik IngressRoute HTTPS + external-dns |
| `ingress-route-tcp.yaml` | Traefik IngressRouteTCP SSH (entrypoint `ssh`) |
| `forgejo-admin.secret.yaml` | **Gitignored** — credentials admin en clair (référence locale) |
| `forgejo-admin.sealed-secret.yaml` | Credentials admin scellés (non déployés, conservés pour référence) |

## Créer le compte admin (une fois, après démarrage)

Le compte admin se crée manuellement via `kubectl exec` une fois Forgejo démarré :

```bash
kubectl exec -n forgejo deploy/forgejo -- \
  forgejo admin user create \
    --admin \
    --username forgejo_admin \
    --password '<mot-de-passe>' \
    --email 'im00jn2t@jbwittner.mailer.me' \
    --must-change-password=false
```

Les credentials sont conservés dans `forgejo-admin.secret.yaml` (gitignored) et `forgejo-admin.sealed-secret.yaml` (référence locale, non inclus dans kustomization).

## Dépendances auto-fournies par CNPG

CNPG génère automatiquement le Secret **`forgejo-db-app`** dans le namespace `forgejo` avec les clés :
`username`, `password`, `host`, `port`, `dbname`, `uri`. Le Deployment et le Job admin les consomment via `valueFrom.secretKeyRef`.

## Quota stockage

Le quota est activé mais le seuil par défaut n'est pas configurable via env var simple (`[quota.default]` est une section INI imbriquée). Pour limiter le stockage total par utilisateur :

```bash
# Via l'API admin Forgejo (après déploiement)
# Connexion : https://forgejo.wittnerlab.com/-/admin/quota/rules
# Ou via API :
TOKEN="<admin-token>"
curl -X POST https://forgejo.wittnerlab.com/api/v1/admin/quota/rules \
  -H "Authorization: token $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"default-limit","limit":32212254720}'  # 30 GiB en octets
```

La PVC de 50Gi constitue la limite physique absolue.

## Déploiement SSH Git (Traefik)

Le port 2222 est exposé via l'entrypoint `ssh` ajouté dans `neltharion/infra/traefik/values.yaml`.
Traefik redémarre lors du premier sync après cet ajout (rolling restart, ~30s d'interruption).

Clone SSH :
```bash
git clone ssh://git@forgejo.wittnerlab.com:2222/jbwittner/mon-repo.git
```

## Vérification

```bash
# Cluster CNPG
kubectl get cluster forgejo-db -n forgejo
kubectl get secret forgejo-db-app -n forgejo -o jsonpath='{.data.host}' | base64 -d

# Pod Forgejo
kubectl get pods -n forgejo
kubectl logs deploy/forgejo -n forgejo

# TLS + DNS
kubectl get certificate forgejo-tls -n forgejo
# → READY = True après ~60s (challenge DNS Let's Encrypt via Cloudflare)

# HTTP
curl -s https://forgejo.wittnerlab.com/api/v1/version | jq .

# SSH
ssh -p 2222 git@forgejo.wittnerlab.com
# → bannière SSH Forgejo
```
