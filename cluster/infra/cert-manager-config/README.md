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
- `manifests/cloudflare-api-token.externalsecret.yaml` — `ExternalSecret` `cloudflare-api-token`
  (ns `cert-manager`, clé `api-token`), servi par [openbao](../openbao/README.md) depuis
  `kv/homelab/cert-manager/cloudflare`

## Contraintes

- Chaque manifeste porte son propre namespace (ClusterIssuer cluster-scoped, Certificates dans
  `gateway`, ExternalSecret dans `cert-manager`) → **pas** de `namespace:` global dans le
  `kustomization.yaml`.
- Les **trois** secrets TLS doivent exister, sinon les listeners correspondants de `shared-gw`
  restent `ResolvedRefs=False`.
- Le nom/namespace du `Secret` produit doivent matcher l'`apiTokenSecretRef` du ClusterIssuer :
  c'est `spec.target.name` de l'`ExternalSecret` qui fait foi, pas son `metadata.name`.
- **`deletionPolicy: Retain` est load-bearing ici plus qu'ailleurs.** OpenBao redémarre scellé à
  chaque redémarrage de son pod (donc à chaque upgrade de son chart) ; sans `Retain`, le Secret
  disparaîtrait et le renouvellement Let's Encrypt — silencieux, tous les 60 j — échouerait sur
  un solver DNS-01 sans token. Ne jamais y toucher.
- **Le composant est en wave `-4`, le coffre en wave `1` : au bootstrap à froid, cet
  `ExternalSecret` est NotReady jusqu'au descellement manuel d'openbao.** Conséquence : les
  `Certificate` wildcard ne s'émettent qu'après cette étape, donc les listeners TLS de `shared-gw`
  restent `ResolvedRefs=False` pendant toute la première partie du bootstrap, et l'Application
  passe `Degraded` en attendant. Rien ne se débloque tout seul : le descellement est un geste
  humain. Même situation que l'Application `argocd` (wave `-1`), qui tire aussi ses secrets du
  coffre.
- **Un spoke qui consommerait ce coffre par `https://openbao.lan.wittner.tech` créerait un
  cycle** : ce nom est servi par `shared-gw` avec un certificat wildcard… émis grâce à ce token.
  Tant qu'ESO ne tourne que sur le hub (accès intra-cluster, cf.
  [external-secrets](../external-secrets/README.md)), le cycle n'existe pas — il apparaîtrait au
  premier spoke consommateur.

## Opérations

### Poser le token API Cloudflare au coffre

> Règle GitOps : aucun secret en clair au cluster ni dans Git
> ([doc/regles-gitops.md](../../../doc/regles-gitops.md)). Le repo ne contient qu'un **pointeur**
> ; la valeur vit dans openbao et n'y arrive par aucun commit.

**Pré-requis** :

1. Un **token API Cloudflare** avec `Zone : DNS : Edit` + `Zone : Zone : Read` sur la zone
   `wittner.tech` — https://dash.cloudflare.com/profile/api-tokens.
2. OpenBao **descellé** : `kubectl -n openbao exec -ti openbao-0 -- bao status`.

Commandes **depuis la racine du repo** :

```bash
# La valeur se pose au coffre, pas dans Git. Aucun commit, aucun kubeseal.
kubectl -n openbao exec -ti openbao-0 -- \
  bao kv put kv/homelab/cert-manager/cloudflare api-token=…

# Vérifier ce que le coffre sert (versionné : `bao kv rollback` rattrape un écrasement)
kubectl -n openbao exec -ti openbao-0 -- bao kv get kv/homelab/cert-manager/cloudflare
```

ESO lit le chemin → matérialise le `Secret` `cloudflare-api-token` (ns `cert-manager`) →
cert-manager résout le DNS-01 → Let's Encrypt émet les wildcards → les `wildcard-*-tls` se
remplissent → `shared-gw` passe `Programmed`.

**Rotation** : régénérer le token côté Cloudflare, refaire le `bao kv put`. Ni commit, ni
redéploiement — ESO reprend la valeur au prochain `refreshInterval` (1 h). Pour l'appliquer tout
de suite :

```bash
kubectl -n cert-manager annotate externalsecret cloudflare-api-token \
  force-sync=$(date +%s) --overwrite
```

⚠️ **Ordre à respecter pour la migration elle-même** : poser la valeur au coffre **avant** de
pousser la suppression du `SealedSecret`. Dans l'autre sens, le prune ArgoCD retire le `Secret`
et le DNS-01 n'a plus de token — sans casse immédiate (les certificats déjà émis restent
valides), mais le prochain renouvellement échoue.

### Vérifier

```bash
kubectl -n cert-manager get externalsecret,secret | command grep cloudflare-api-token
kubectl -n cert-manager describe externalsecret cloudflare-api-token   # SecretSynced attendu
kubectl -n gateway get certificate
kubectl -n gateway describe certificate wildcard-lan-tls   # events DNS-01 / issuance
kubectl get clusterissuer letsencrypt-prod -o wide
```
