# cert-manager

## Rôle

Émission et renouvellement automatiques des certificats TLS (Let's Encrypt, DNS-01 Cloudflare).
Le composant porte **le moteur et ses objets métier** : le contrôleur Jetstack, les
`ClusterIssuer`, les `Certificate` wildcard et le token Cloudflare du solver. cert-manager
remplit les Secret TLS `wildcard-*-tls` dans le namespace `gateway`, là où `shared-gw` les
consomme (cf. [doc/reseau.md](../../../doc/reseau.md)).

## Fichiers

- `cert-manager.app.yaml` — Application (archétype (b) : chart Helm + `$values` + `manifests/`),
  ns `cert-manager`, wave `-5`
- `helm-values.yaml` — `crds.enabled: true` + `crds.keep: true` (les CRDs survivent à une
  désinstallation du chart, donc les `Certificate` existants ne sont pas emportés)
- `manifests/clusterissuer-prod.yaml` / `manifests/clusterissuer-staging.yaml` — les deux
  `ClusterIssuer` ACME, solver `dns01.cloudflare` → `apiTokenSecretRef` sur le Secret scellé
- `manifests/certificates.yaml` — les `Certificate` wildcard (`*.wittner.tech`,
  `*.lan.wittner.tech`), **ns `gateway`**
- `manifests/cloudflare-api-token.sealed.yaml` — `SealedSecret` `cloudflare-api-token`
  (ns `cert-manager`, clé `api-token`), déchiffré en cluster par
  [sealed-secrets](../sealed-secrets/README.md)
- `manifests/cloudflare-api-token.secret.yaml` — **clair, gitignoré** : template d'entrée de
  `kubeseal`, à supprimer après scellement

## Contraintes

> [!IMPORTANT]
> **Moteur et objets métier sont dans la MÊME Application, et c'est délibéré.** Ils ont vécu
> séparés (`cert-manager` wave `-5` / `cert-manager-config` wave `-4`), ce qui obligeait à tenir
> un ordre entre deux Applications pour une raison purement technique : les CRDs
> `ClusterIssuer`/`Certificate` sont posées par le chart. Activer l'un sans l'autre échouait en
> `no matches for kind`, sans que rien dans le repo ne le signale. L'ordre est désormais
> **interne** à l'app.

- Wave **-5** : après les CRDs Gateway API (`-10`), avant tout consommateur de certificat.
- **Ordre interne, par sync-waves de ressources.** Le chart est en wave `0` ; les `ClusterIssuer`
  et `Certificate` portent `argocd.argoproj.io/sync-wave: "1"`. Argo attend que la wave `0` soit
  Healthy — donc le webhook d'admission cert-manager joignable — avant de poser les objets métier.
  Sans ça, l'apply est rejeté en `failed calling webhook "webhook.cert-manager.io"`. Même schéma
  que [kube-prometheus-stack](../../app/kube-prometheus-stack/README.md), dont le chart pose les
  CRDs que consomme son propre `manifests/`.
- Les CRDs sont posées par le chart, pas par un manifeste : ne pas les dupliquer ailleurs.
- Chaque manifeste de `manifests/` porte son propre namespace (ClusterIssuer cluster-scoped,
  Certificates dans `gateway`, SealedSecret dans `cert-manager`) → **pas** de `namespace:` global
  dans le `kustomization.yaml`.
- Les secrets TLS doivent exister, sinon les listeners correspondants de `shared-gw` restent
  `ResolvedRefs=False`.
- **Le `SealedSecret` est chiffré pour le couple (`cloudflare-api-token`, `cert-manager`).** Le
  déplacer d'un namespace ou le renommer le rend indéchiffrable — il faut le resceller.
- **La clé privée du contrôleur sealed-secrets est une dépendance de renouvellement TLS.** Un
  contrôleur redémarré sans clé restaurée régénère une clé neuve : le token n'est plus
  déchiffrable, et le renouvellement Let's Encrypt — silencieux, tous les 60 j — échoue sur un
  solver DNS-01 sans token. Cf. l'encadré CAUTION de
  [sealed-secrets](../sealed-secrets/README.md).
- **La rotation du token est un commit.** Contrairement au canal openbao, changer le token impose
  `kubeseal` + commit + sync. C'est le coût assumé de ce canal, en échange d'un token
  déchiffrable dès la wave `-8` — donc sans attendre le descellement manuel d'openbao (wave `1`).

## Opérations

### Sceller le token API Cloudflare

> Règle GitOps : aucun secret en clair au cluster ni dans Git. Ici le repo porte la valeur, mais
> **chiffrée** pour la clé publique du contrôleur : seul le cluster peut la relire.

**Pré-requis** :

1. Un **token API Cloudflare** avec `Zone : DNS : Edit` + `Zone : Zone : Read` sur la zone
   `wittner.tech` — https://dash.cloudflare.com/profile/api-tokens.
2. Le contrôleur **sealed-secrets** en place (wave `-8`) et sa clé restaurée.

Commandes **depuis la racine du repo** :

```bash
# 1. Renseigner la valeur dans le template en clair (gitignoré)
$EDITOR cluster/infra/cert-manager/manifests/cloudflare-api-token.secret.yaml

# 2. Sceller
kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
  < cluster/infra/cert-manager/manifests/cloudflare-api-token.secret.yaml \
  > cluster/infra/cert-manager/manifests/cloudflare-api-token.sealed.yaml

# 3. Supprimer le clair, puis committer
rm cluster/infra/cert-manager/manifests/cloudflare-api-token.secret.yaml
```

Le contrôleur déchiffre → `Secret` `cloudflare-api-token` (ns `cert-manager`) → cert-manager
résout le DNS-01 → Let's Encrypt émet les wildcards → les `wildcard-*-tls` se remplissent →
`shared-gw` passe `Programmed`.

**Rotation** : régénérer le token côté Cloudflare, refaire les étapes 1→3, committer.

> [!WARNING]
> **Résidu de l'ancien canal openbao.** L'`ExternalSecret` qui servait ce token était en
> `deletionPolicy: Retain` : le prune ArgoCD le retire, mais le `Secret` `cloudflare-api-token`
> qu'il avait matérialisé **survit**. sealed-secrets refuse alors d'écrire par-dessus un Secret
> dont il n'est pas propriétaire (`already exists and is not managed by SealedSecret`) :
>
> ```bash
> # soit supprimer le résidu (les certificats déjà émis restent valides le temps du trou)
> kubectl -n cert-manager delete secret cloudflare-api-token
>
> # soit le céder au contrôleur
> kubectl -n cert-manager annotate secret cloudflare-api-token \
>   sealedsecrets.bitnami.com/managed=true --overwrite
> ```

### Upgrade

Bumper `targetRevision` dans `cert-manager.app.yaml`, commit, push.

### Vérifier

```bash
kubectl get crd sealedsecrets.bitnami.com clusterissuers.cert-manager.io
kubectl -n cert-manager get sealedsecret,secret | command grep cloudflare-api-token
kubectl -n cert-manager describe sealedsecret cloudflare-api-token   # « no key could decrypt » = mauvaise clé
kubectl get clusterissuer letsencrypt-prod -o wide
kubectl -n gateway get certificate
kubectl -n gateway describe certificate wildcard-lan-tls   # events DNS-01 / issuance
```

### Debug émission

```bash
kubectl -n gateway get certificate
kubectl -n gateway describe certificaterequest
kubectl -n cert-manager get challenges
kubectl -n cert-manager logs deploy/cert-manager
```

**Challenge DNS-01 bloqué en `Pending`** : le self-check de propagation passe par le DNS **du
cluster**. Si un upstream renvoie NXDOMAIN sur `_acme-challenge`, rien n'aboutit. Remède
(non appliqué aujourd'hui, à ajouter dans `helm-values.yaml` si le cas se représente) :

```yaml
extraArgs:
  - --dns01-recursive-nameservers=1.1.1.1:53
  - --dns01-recursive-nameservers-only
```

Après un run avorté, purger les TXT `_acme-challenge` orphelins côté Cloudflare.
