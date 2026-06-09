# Authentik

Solution complète de gestion des identités et des accès (SSO/OIDC) pour le cluster neltharion.

Applications déléguant leur authentification à Authentik :
- ArgoCD (SSO patches à appliquer après déploiement — voir `CLAUDE.md`)
- Grafana

## URL

- **URL** : https://authentik.wittnerlab.com

## Exposition (IngressRoute, pas Ingress k8s)

L'accès se fait par une **`IngressRoute` Traefik** (`ingress-route.yaml`), pas par l'`Ingress`
du chart. `values.yaml` met donc `server.ingress.enabled: false` : avec un Traefik en
ClusterIP/hostPort, l'`Ingress` k8s du chart resterait `Progressing` à l'infini dans Argo
(personne ne remplit `.status.loadBalancer.ingress` attendu par le health-check Ingress).

Le TLS est fourni par cert-manager via `certificate.yaml` (`Certificate` `authentik-tls`,
ClusterIssuer `letsencrypt-prod`), dont le secret `authentik-tls` est référencé par
l'`IngressRoute`.

## Dépendances

- **Wave 2** : `cnpg` (opérateur CloudNativePG requis pour `authentik-db`)
- **Wave 3** : ce composant

## Base de données

`authentik-db.yaml` déclare un `Cluster` CNPG à 1 instance. CNPG crée automatiquement le secret
`authentik-db-app` (namespace `authentik`) avec les clés `username`, `password`, `host`, `port`,
`dbname`. C'est ce secret que `values.yaml` référence via `secretKeyRef` — aucun SealedSecret
manuel n'est nécessaire pour les credentials DB.

## Sealed Secrets

Aucun SealedSecret n'est actif pour ce composant (l'état actuel). CNPG gère les credentials
automatiquement.

Si tu as besoin d'un secret Postgres manuel (ex. imposer un mot de passe fixe via
`bootstrap.initdb.secret`), voici la procédure complète :

1. Créer le plaintext `neltharion/apps/authentik/authentik.secret.yaml` (gitignored par `*.secret.yaml`) :

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: authentik-postgres-credentials
  namespace: authentik
type: kubernetes.io/basic-auth
stringData:
  username: authentik
  password: <MOT_DE_PASSE>
```

2. Sceller depuis la racine du repo contre le contrôleur neltharion :

```bash
kubeseal --controller-name=sealed-secrets --controller-namespace=sealed-secrets --format yaml \
  < neltharion/apps/authentik/authentik.secret.yaml \
  > neltharion/apps/authentik/authentik.sealed-secret.yaml
```

Repli offline (sans accès cluster) : `kubeseal --fetch-cert … > pub-cert.pem` puis `--cert pub-cert.pem`
(cf. [`../../infra/sealed-secrets/README.md`](../../infra/sealed-secrets/README.md)).

3. Committer le sealed-secret (le `.secret.yaml` en clair reste gitignored) :

```bash
git add neltharion/apps/authentik/authentik.sealed-secret.yaml
```

4. Ajouter `authentik.sealed-secret.yaml` dans `kustomization.yaml` et référencer le secret
   dans `authentik-db.yaml` (champ `bootstrap.initdb.secret`) et `values.yaml`.

## `secret_key` Authentik

La clé de signature Authentik (`authentik.secret_key` dans `values.yaml`) est actuellement en
clair. Pour la mettre en secret scellé, créer `authentik-secret-key.secret.yaml` (gitignored)
avec la valeur souhaitée, sceller, et la référencer via `env.valueFrom.secretKeyRef`.

## Vérification

```bash
kubectl get application authentik -n argocd
kubectl get pods -n authentik
kubectl get cluster authentik-db -n authentik
kubectl logs -n authentik -l app.kubernetes.io/name=authentik
```
