# Traefik

Ingress controller déployé via Helm chart (wave 0), configuré pour un nœud bare-metal sans LoadBalancer.

## Architecture

Le cluster n'a pas de LoadBalancer externe. Traefik écoute directement sur les ports du nœud via `hostPort` :

| Port nœud | Port interne | Entrypoint |
|-----------|-------------|------------|
| 80        | 8000        | `web`      |
| 443       | 8443        | `websecure` |

Le Service est en `ClusterIP` — le trafic externe entre par les `hostPort`, pas par le Service.

## Redirection HTTP → HTTPS

La redirection est configurée via `additionalArguments` avec le port cible `:443` explicite :

```yaml
additionalArguments:
  - "--entrypoints.web.http.redirections.entrypoint.to=:443"
  - "--entrypoints.web.http.redirections.entrypoint.scheme=https"
```

**Pourquoi `:443` et pas `websecure` ?**
Avec `to=websecure`, Traefik construit l'URL de redirection à partir du port interne de l'entrypoint (`8443`), pas de l'`exposedPort`. Le client reçoit alors une redirection vers `:8443`. En spécifiant `:443` directement, le port dans l'URL de redirection est forcé à 443.

**Pourquoi `additionalArguments` et pas un `Middleware RedirectScheme` ?**
Même problème : `RedirectScheme` sans `port` explicite utilise le port interne. Avec `port: "443"` le comportement est correct mais moins lisible — la config au niveau de l'entrypoint est plus idiomatique pour une redirection globale.

## TLS

Traefik ne gère pas les certificats. C'est cert-manager (wave 1) qui émet les certificats via Let's Encrypt et les stocke comme Secrets. Chaque `IngressRoute` référence son Secret TLS directement.

## Exposer une application

Créer deux ressources dans le namespace de l'app :

```yaml
# IngressRoute HTTPS uniquement (HTTP est redirigé globalement)
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: myapp
  namespace: myapp
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`myapp.wittnerlab.com`)
      kind: Rule
      services:
        - name: myapp
          port: 80
  tls:
    secretName: myapp-tls  # créé par un Certificate cert-manager
```

```yaml
# Certificate cert-manager
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: myapp-tls
  namespace: myapp
spec:
  secretName: myapp-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - myapp.wittnerlab.com
```

## Dashboard

Désactivé par défaut. Pour y accéder en local :

```bash
kubectl port-forward -n traefik deploy/traefik 9000:9000
# puis ouvrir http://localhost:9000/dashboard/
```
