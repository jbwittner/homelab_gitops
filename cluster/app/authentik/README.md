# authentik

## Rôle

Identity Provider du homelab (SSO : OIDC, SAML, LDAP, proxy). Base de données PostgreSQL dédiée,
portée par un `Cluster` CNPG (opérateur fourni par [`cnpg`](../cnpg/README.md)). Exposé
publiquement sur `https://authentik.wittner.tech` via `shared-gw` (listener `https-public`,
cf. [doc/reseau.md](../../../doc/reseau.md)).

C'est le fournisseur d'identité de [`argocd`](../../infra/argocd/README.md) et de
[`kube-prometheus-stack`](../kube-prometheus-stack/README.md) : les Providers, Applications et
groupes côté authentik sont gérés en **Terraform** (autre repo), pas ici.

## Fichiers

- `authentik.app.yaml` — Application (archétype (b) : chart + `$values` + `manifests/`)
- `helm-values.yaml` — postgres bundlé désactivé, connexion au Cluster CNPG `authentik-db`,
  `AUTHENTIK_SECRET_KEY` et mot de passe DB injectés par `secretKeyRef`
- `manifests/namespace.yaml` — ns `authentik`
- `manifests/authentik-db.yaml` — `Cluster` CNPG (l'opérateur génère le service
  `authentik-db-rw` et le secret `authentik-db-app`)
- `manifests/authentik-secrets.sealed.yaml` — SealedSecret `authentik-secrets`, clé `secret-key`
- `manifests/authentik-httproute.yaml` — HTTPRoute → `shared-gw`
- `manifests/kustomization.yaml` — assemblage

## Contraintes

> [!CAUTION]
> **`AUTHENTIK_SECRET_KEY` ne se change jamais après la première installation.** Il chiffre des
> données en base (tokens, sessions) : le remplacer invalide ce qui a été chiffré avec l'ancien.
> Une « rotation » n'est pas une opération anodine mais une remise à plat.

- Le mot de passe DB n'est **pas** géré ici : il vient du secret auto-généré par CNPG
  (`authentik-db-app`). Ne pas le sceller, ne pas le figer.
- L'ingress/route du chart reste désactivé : l'exposition passe par le HTTPRoute du dossier.
- Le composant `cnpg` doit tourner avant : sans la CRD `Cluster`, le manifeste DB échoue.

## Opérations

- **Première connexion** : `https://authentik.wittner.tech/if/flow/initial-setup/` pour définir
  le mot de passe de l'utilisateur `akadmin`.
- **État de la base** (read-only) :
  ```bash
  kubectl -n authentik get cluster
  kubectl -n authentik get pods
  ```
- **Générer et sceller le `secret-key`** (première installation) — depuis la racine du repo :
  ```bash
  kubectl create secret generic authentik-secrets -n authentik --dry-run=client -o yaml \
    --from-literal=secret-key="$(openssl rand -base64 60 | tr -d '\n')" \
  | kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
    > cluster/app/authentik/manifests/authentik-secrets.sealed.yaml
  ```
  Puis commit + push.
- **Logs** : `kubectl -n authentik logs deploy/authentik-server`,
  `kubectl -n authentik logs deploy/authentik-worker`.
