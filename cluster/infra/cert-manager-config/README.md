# cert-manager-config

## Rôle

Les objets métier de cert-manager : `ClusterIssuer` Let's Encrypt (DNS-01 Cloudflare) et les
`Certificate` wildcard. cert-manager remplit les Secret TLS `wildcard-*-tls` dans le namespace
`gateway`, là où `shared-gw` les consomme (cf. [doc/reseau.md](../../../doc/reseau.md)).

## Fichiers

- `cert-manager-config.app.yaml` — Application (archétype (c), path → `manifests/`), wave -4
- `manifests/clusterissuer.yaml` — `letsencrypt-prod`, ACME production, solver
  `dns01.cloudflare` → `apiTokenSecretRef` sur le Secret servi par openbao
- `manifests/certificates.yaml` — les 3 `Certificate` wildcard (`*.wittner.tech`,
  `*.lan.wittner.tech`, `*.kalecgos.lan.wittner.tech`), **ns `gateway`**
- `manifests/cloudflare-api-token.sealed.yaml` — `SealedSecret` `cloudflare-api-token`
  (ns `cert-manager`, clé `api-token`), déchiffré en cluster par
  [sealed-secrets](../sealed-secrets/README.md). **À sceller** : la ligne est commentée dans
  `kustomization.yaml` tant que le fichier n'existe pas (cf. §Sceller le token)
- `manifests/cloudflare-api-token.secret.yaml` — **clair, gitignoré** : template d'entrée de
  `kubeseal`, à supprimer après scellement

## Contraintes

- Chaque manifeste porte son propre namespace (ClusterIssuer cluster-scoped, Certificates dans
  `gateway`, SealedSecret dans `cert-manager`) → **pas** de `namespace:` global dans le
  `kustomization.yaml`.
- Les secrets TLS doivent exister, sinon les listeners correspondants de `shared-gw` restent
  `ResolvedRefs=False`.
- Le nom/namespace du `Secret` produit doivent matcher l'`apiTokenSecretRef` des ClusterIssuer :
  c'est `spec.template.metadata` du `SealedSecret` qui fait foi.
- **Le `SealedSecret` est chiffré pour le couple (`cloudflare-api-token`, `cert-manager`).** Le
  déplacer d'un namespace ou le renommer le rend indéchiffrable — il faut le resceller.
- **La clé privée du contrôleur sealed-secrets devient une dépendance de renouvellement TLS.**
  Un contrôleur redémarré sans clé restaurée régénère une clé neuve : le token n'est plus
  déchiffrable, et le renouvellement Let's Encrypt — silencieux, tous les 60 j — échoue sur un
  solver DNS-01 sans token. Cf. l'encadré CAUTION de
  [sealed-secrets](../sealed-secrets/README.md).
- **Le composant est en wave `-4`, le contrôleur sealed-secrets en wave `-8`** : l'ordre est bon,
  le `SealedSecret` se déchiffre dès la première sync. C'est le gain de ce canal par rapport au
  coffre (wave `1`, descellement manuel) : plus d'attente d'un geste humain au bootstrap à froid
  avant que les `Certificate` wildcard ne s'émettent.
- **La rotation redevient un commit.** Contrairement au canal openbao, changer le token impose
  `kubeseal` + commit + sync — c'est le coût assumé de ce canal (cf.
  [doc/regles-gitops.md](../../../doc/regles-gitops.md)).

## Opérations

### Sceller le token API Cloudflare

> Règle GitOps : aucun secret en clair au cluster ni dans Git
> ([doc/regles-gitops.md](../../../doc/regles-gitops.md)). Ici le repo porte la valeur, mais
> **chiffrée** pour la clé publique du contrôleur : seul le cluster peut la relire.

**Pré-requis** :

1. Un **token API Cloudflare** avec `Zone : DNS : Edit` + `Zone : Zone : Read` sur la zone
   `wittner.tech` — https://dash.cloudflare.com/profile/api-tokens.
2. Le contrôleur **sealed-secrets** en place (wave `-8`) et sa clé restaurée.

Commandes **depuis la racine du repo** :

```bash
# 1. Renseigner la valeur dans le template en clair (gitignoré)
$EDITOR cluster/infra/cert-manager-config/manifests/cloudflare-api-token.secret.yaml

# 2. Sceller
kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
  < cluster/infra/cert-manager-config/manifests/cloudflare-api-token.secret.yaml \
  > cluster/infra/cert-manager-config/manifests/cloudflare-api-token.sealed.yaml

# 3. Supprimer le clair, décommenter la ligne dans kustomization.yaml, committer les deux
#    ensemble (une ligne référencée sans fichier casse `kustomize build`).
rm cluster/infra/cert-manager-config/manifests/cloudflare-api-token.secret.yaml
```

Le contrôleur déchiffre → `Secret` `cloudflare-api-token` (ns `cert-manager`) → cert-manager
résout le DNS-01 → Let's Encrypt émet les wildcards → les `wildcard-*-tls` se remplissent →
`shared-gw` passe `Programmed`.

**Rotation** : régénérer le token côté Cloudflare, refaire les étapes 1→3, committer. Contrairement
au canal openbao, la rotation demande un commit et une sync.

> [!WARNING]
> **Migration depuis le canal openbao — le Secret résiduel bloque le contrôleur.** L'ancien
> `ExternalSecret` était en `deletionPolicy: Retain` : le prune ArgoCD le retire, mais le `Secret`
> `cloudflare-api-token` qu'il avait matérialisé **survit**. sealed-secrets refuse alors d'écrire
> par-dessus un Secret dont il n'est pas propriétaire (`already exists and is not managed by
> SealedSecret`). Avant la première sync du `SealedSecret`, faire l'un des deux :
>
> ```bash
> # soit supprimer le résidu (les certificats déjà émis restent valides le temps du trou)
> kubectl -n cert-manager delete secret cloudflare-api-token
>
> # soit le céder au contrôleur
> kubectl -n cert-manager annotate secret cloudflare-api-token \
>   sealedsecrets.bitnami.com/managed=true --overwrite
> ```
>
> Et poser le `.sealed.yaml` **avant** de laisser le prune passer : dans l'autre sens le DNS-01
> n'a plus de token — sans casse immédiate, mais le prochain renouvellement échoue.

### Vérifier

```bash
kubectl -n cert-manager get sealedsecret,secret | command grep cloudflare-api-token
kubectl -n cert-manager describe sealedsecret cloudflare-api-token   # events : « no key could decrypt » = mauvaise clé
kubectl -n gateway get certificate
kubectl -n gateway describe certificate wildcard-lan-tls   # events DNS-01 / issuance
kubectl get clusterissuer letsencrypt-prod -o wide
```
