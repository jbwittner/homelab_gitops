# cert-manager-config

## Rôle

Les objets métier de cert-manager : `ClusterIssuer` Let's Encrypt (DNS-01 Cloudflare) et les
`Certificate` wildcard. cert-manager remplit les Secret TLS `wildcard-*-tls` dans le namespace
`gateway`, là où `shared-gw` les consomme (cf. [doc/reseau.md](../../../doc/reseau.md)).

## Fichiers

- `cert-manager-config.app.yaml` — Application (archétype (c), path → `manifests/`), wave -4
- `manifests/clusterissuer.yaml` — `letsencrypt-prod`, ACME production, solver
  `dns01.cloudflare` → `apiTokenSecretRef` sur le SealedSecret
- `manifests/certificates.yaml` — les 3 `Certificate` wildcard (`*.wittner.tech`,
  `*.lan.wittner.tech`, `*.kalecgos.lan.wittner.tech`), **ns `gateway`**
- `manifests/cloudflare-api-token.sealed.yaml` — SealedSecret `cloudflare-api-token`
  (ns `cert-manager`, clé `api-token`)
- `manifests/cloudflare-api-token.secret.yaml` — template en clair, **gitignoré**

## Contraintes

- Chaque manifeste porte son propre namespace (ClusterIssuer cluster-scoped, Certificates dans
  `gateway`, SealedSecret dans `cert-manager`) → **pas** de `namespace:` global dans le
  `kustomization.yaml`.
- Les **trois** secrets TLS doivent exister, sinon les listeners correspondants de `shared-gw`
  restent `ResolvedRefs=False`.
- Le nom/namespace du SealedSecret doit matcher l'`apiTokenSecretRef` du ClusterIssuer.

## Opérations

### Sceller le token API Cloudflare

> Règle GitOps : aucun secret en clair au cluster ni dans Git
> ([doc/regles-gitops.md](../../../doc/regles-gitops.md)).

**Pré-requis** :

1. Un **token API Cloudflare** avec `Zone : DNS : Edit` + `Zone : Zone : Read` sur la zone
   `wittner.tech` — https://dash.cloudflare.com/profile/api-tokens.
2. Contrôleur sealed-secrets en marche : `kubectl get deploy -n sealed-secrets`.
3. `kubeseal` installé.

Commandes **depuis la racine du repo** :

```bash
# 1. Renseigner la clé `api-token` du template en clair (gitignoré) :
#    cluster/infra/cert-manager-config/manifests/cloudflare-api-token.secret.yaml

# 2. Sceller
kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
  < cluster/infra/cert-manager-config/manifests/cloudflare-api-token.secret.yaml \
  > cluster/infra/cert-manager-config/manifests/cloudflare-api-token.sealed.yaml

# 3. Supprimer le clair, puis commit + push
rm cluster/infra/cert-manager-config/manifests/cloudflare-api-token.secret.yaml
```

ArgoCD sync → le contrôleur déchiffre `cloudflare-api-token` → cert-manager résout le DNS-01 →
Let's Encrypt émet les wildcards → les `wildcard-*-tls` se remplissent → `shared-gw` passe
`Programmed`.

**Rotation** : régénérer le token côté Cloudflare, refaire les 3 étapes. L'ancien Secret est
écrasé au sync suivant.

### Vérifier

```bash
kubectl -n cert-manager get sealedsecret,secret | command grep cloudflare-api-token
kubectl -n gateway get certificate
kubectl -n gateway describe certificate wildcard-kalecgos-lan-tls   # events DNS-01 / issuance
kubectl get clusterissuer letsencrypt-prod -o wide
```
