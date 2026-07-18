# authentik

## Rôle

Identity Provider (SSO : OIDC, SAML, LDAP, proxy) du cluster. Chart Helm officiel
authentik, base de données PostgreSQL dédiée portée par un `Cluster` CNPG (opérateur
fourni par le composant `cnpg`). Exposé publiquement sur
`https://authentik.wittner.tech` via le `Gateway` partagé `shared-gw` (listener
`https-public`).

## Fichiers

- `authentik.app.yaml` — Application ArgoCD multi-sources : chart Helm + values (`$values`)
  + `manifests/`.
- `helm-values.yaml` — values du chart : postgres bundlé désactivé, connexion au Cluster
  CNPG `authentik-db`, `AUTHENTIK_SECRET_KEY` et password DB injectés par `secretKeyRef`.
- `manifests/namespace.yaml` — namespace `authentik`.
- `manifests/authentik-db.yaml` — `Cluster` CNPG (l'opérateur génère le service
  `authentik-db-rw` et le secret `authentik-db-app`).
- `manifests/authentik-secrets.sealed.yaml` — SealedSecret contenant `secret-key`
  (`AUTHENTIK_SECRET_KEY` — ne jamais changer après la première installation).
- `manifests/authentik-httproute.yaml` — HTTPRoute → `shared-gw`.
- `manifests/kustomization.yaml` — assemblage des manifestes.

## Opérations

- Première connexion : `https://authentik.wittner.tech/if/flow/initial-setup/` pour créer
  le mot de passe de l'utilisateur `akadmin`.
- Régénérer le secret (rotation) :
  `kubectl create secret generic authentik-secrets -n authentik --dry-run=client
  --from-literal=secret-key="$(openssl rand -base64 60 | tr -d '\n')" -o yaml |
  kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets
  --format yaml > manifests/authentik-secrets.sealed.yaml` puis commit/push.
- État de la DB : `kubectl get cluster -n authentik` (read-only).
