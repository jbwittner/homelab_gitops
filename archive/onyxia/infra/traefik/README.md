# Traefik

Ingress controller déployé via Helm chart (wave 0), configuré pour un nœud bare-metal sans LoadBalancer.

## Architecture

Pas de LoadBalancer externe : Traefik écoute directement sur les ports du nœud via `hostPort`.

| Port nœud | Port interne | Entrypoint  |
|-----------|-------------|-------------|
| 80        | 8000        | `web`       |
| 443       | 8443        | `websecure` |

Le Service est en `ClusterIP` — le trafic externe entre par les `hostPort`, pas par le Service.

## Redirection HTTP → HTTPS

Configurée via `additionalArguments` avec le port cible `:443` explicite :

```yaml
additionalArguments:
  - "--entrypoints.web.http.redirections.entrypoint.to=:443"
  - "--entrypoints.web.http.redirections.entrypoint.scheme=https"
```

`to=:443` (et pas `to=websecure`) : sinon Traefik construit l'URL de redirection à partir du port
interne (`8443`) au lieu de l'`exposedPort`.

## TLS

Traefik ne gère pas les certificats. **cert-manager** (wave 1) émet les certs via Let's Encrypt
(DNS-01 Cloudflare) et les stocke comme Secrets. Chaque `IngressRoute` référence son Secret TLS.

## Exposer une application (HTTPS + cert Let's Encrypt)

Deux ressources dans le namespace de l'app :

```yaml
# Certificate cert-manager → émet le Secret TLS
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: myapp-tls
  namespace: myapp
spec:
  secretName: myapp-tls
  issuerRef:
    name: letsencrypt-prod        # letsencrypt-staging le temps d'itérer
    kind: ClusterIssuer
  dnsNames:
    - myapp.example.com
---
# IngressRoute HTTPS (HTTP redirigé globalement)
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: myapp
  namespace: myapp
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`myapp.example.com`)
      kind: Rule
      services:
        - name: myapp
          port: 80
  tls:
    secretName: myapp-tls          # créé par le Certificate ci-dessus
```

> Les `ClusterIssuer` (`letsencrypt-prod` / `letsencrypt-staging`) sont fonctionnels **une fois le
> token Cloudflare scellé** — voir [`../cert-manager/README.md`](../cert-manager/README.md).

## Dashboard

Désactivé par défaut. Accès local :

```bash
kubectl port-forward -n traefik deploy/traefik 9000:9000
# http://localhost:9000/dashboard/
```
