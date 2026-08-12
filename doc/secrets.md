# Secrets — architecture

Comment un secret arrive dans un pod. Les **règles** (quel canal pour quel secret, ce qui reste
scellé et pourquoi) vivent dans [regles-gitops.md](regles-gitops.md) ; ce document décrit le
**mécanisme**.

## Deux canaux, un même résultat

| Canal | Composant | Où vit le chiffré | Fichier committé |
|---|---|---|---|
| 1 | [sealed-secrets](../cluster/infra/sealed-secrets/README.md) | **dans Git**, chiffré pour la clé du cluster | `<name>.sealed.yaml` |
| 2 | [openbao](../cluster/infra/openbao/README.md) + [external-secrets](../cluster/infra/external-secrets/README.md) | **dans le PVC** du coffre, hors Git | `<name>.externalsecret.yaml` — un pointeur, aucun chiffré |

Les deux produisent un `Secret` Kubernetes **ordinaire**. C'est ce qui rend le choix du canal
invisible aux consommateurs : Grafana, ArgoCD, authentik et Renovate lisent un `Secret` du même
nom avec les mêmes clés, qu'il vienne de l'un ou de l'autre. Migrer un secret d'un canal à
l'autre ne touche pas le composant qui le consomme.

## Le canal openbao : trois objets

⚠️ Malgré son nom, **un `ClusterSecretStore` ne stocke aucun secret**. C'est une fiche de
connexion : *où* est le coffre, *comment* s'y authentifier, *quel* moteur y lire.

| Objet | Portée | Ce qu'il porte |
|---|---|---|
| `ClusterSecretStore` | cluster | **le « où » et le « comment »** — adresse d'openbao, moteur KV, méthode d'auth. Un par cluster |
| `ExternalSecret` | namespace | **le « quoi »** — quel chemin lire, quelles clés, dans quel `Secret` les écrire. Un par secret |
| `Secret` | namespace | le résultat, un Secret Kubernetes ordinaire |

La chaîne complète, sur l'exemple du client-secret OIDC de Grafana :

```
ClusterSecretStore/openbao              « openbao est à http://openbao.openbao.svc:8200,
  cluster/infra/external-secrets/         moteur kv v2 ; je m'authentifie sur le mount
  bleu-kalecgos/manifests/                kubernetes-bleu-kalecgos avec mon ServiceAccount »
        ▲
        │ secretStoreRef
        │
ExternalSecret/grafana-oidc             « prends kv/homelab/grafana/oidc, clé client-secret,
  ns monitoring                           écris-la dans le Secret grafana-oidc »
  cluster/app/kube-prometheus-stack/
  manifests/grafana-oidc.externalsecret.yaml
        │
        ▼
Secret/grafana-oidc                     lu par Grafana via envValueFrom.secretKeyRef —
  ns monitoring                           exactement comme du temps de sealed-secrets
```

L'inventaire des chemins KV et de leurs consommateurs est dans
[`cluster/infra/openbao`](../cluster/infra/openbao/README.md), table « Contenu du coffre ».

⚠️ **Un seul secrets engine, plusieurs méthodes d'auth.** Les deux notions sont indépendantes, et
OpenBao emploie le mot « kubernetes » des deux côtés pour deux choses opposées — l'engine
*fabrique* des ServiceAccounts éphémères, l'auth *consomme* un token pour identifier un client.

| | Rôle | Combien |
|---|---|---|
| Secrets engine (`kv` v2) | *où* sont rangés les secrets | **1**, partagé — le coffre ne dépend d'aucun cluster |
| Auth method (`kubernetes-<cluster>`) | *comment* un client prouve qui il est | **1 par cluster** — chaque mount est lié à un API server |

Ce que Terraform doit poser exactement : [openbao-terraform.md](openbao-terraform.md).

## Pourquoi `ClusterSecretStore` et pas `SecretStore`

ESO offre les deux. `SecretStore` est **namespacé** : il n'est utilisable que par les
`ExternalSecret` de son propre namespace. Nos secrets vivent dans **quatre** namespaces
(`argocd`, `authentik`, `monitoring`, `renovate`) — il faudrait quatre copies du même objet, à
maintenir en parallèle. La version cluster-scoped en pose une seule, référençable de partout.

Corollaire : comme l'objet n'a pas de namespace, son `serviceAccountRef` doit être **qualifié**
(`name` + `namespace`), sinon ESO ne sait pas dans quel namespace chercher le ServiceAccount.

## Un store par cluster, et ce n'est pas un choix de style

ESO ne tourne aujourd'hui que sur le **hub**
([`Application`](../cluster/infra/external-secrets/README.md)) : c'est le seul cluster qui consomme
des secrets du coffre. Ce n'est pas extensible gratuitement — un `Secret` Kubernetes ne traverse pas
les clusters, donc **chaque** cluster consommateur doit matérialiser localement ce qu'il lit, avec
son propre contrôleur et son propre store. Le coffre, lui, reste unique et vit sur le hub.

| | hub (`bleu-kalecgos`) | un futur spoke consommateur |
|---|---|---|
| `server` | `http://openbao.openbao.svc.cluster.local:8200` | `https://openbao.lan.wittner.tech` — via `shared-gw` |
| `mountPath` | `kubernetes-bleu-kalecgos` | `kubernetes-<cluster>` |

- **L'adresse** : `openbao.openbao.svc` ne résout pas depuis un spoke. On repasserait par
  l'exposition du coffre sur `shared-gw` ([reseau.md](reseau.md)), donc en HTTPS — certificat
  Let's Encrypt, chaîne publiquement approuvée, aucun `caProvider` à déclarer.
- **Le mount d'auth** : une méthode d'auth `kubernetes` d'openbao est configurée pour **un** API
  server (issuer, CA, TokenReview). Un mount partagé ne saurait pas valider les tokens émis par
  les autres clusters. Pour un spoke, le mount exige en plus `kubernetes_host`,
  `kubernetes_ca_cert` et un `token_reviewer_jwt` : openbao n'a aucun accès local à l'API
  TokenReview d'un cluster distant.

Le **nom du store est `openbao`**, et c'est load-bearing : les `ExternalSecret` le référencent sans
savoir sur quel cluster ils tournent, ce qui rend un composant déplaçable d'un cluster à l'autre
sans retoucher ses secrets — à condition de garder ce nom sur tout cluster ajouté.

> [!IMPORTANT]
> **Aucun credential d'amorçage.** ESO forge un token pour son propre ServiceAccount via l'API
> TokenRequest et le présente à openbao. C'est ce qui permet d'ajouter ce canal **sans ajouter de
> `SealedSecret`** — et donc de tenir le repo à deux scellés seulement.

## Ce qui se passe quand le coffre est scellé

OpenBao redémarre **scellé**, à chaque redémarrage de son pod (donc à chaque upgrade de son
chart). Le store devient injoignable. Conséquences, dans l'ordre de gravité :

1. **Les `Secret` déjà matérialisés survivent** — grâce à `deletionPolicy: Retain`, obligatoire
   sur tous les `ExternalSecret` du repo. Les charges continuent de tourner : SSO, Grafana,
   Renovate, authentik.
2. **Les `ExternalSecret` passent `NotReady`** : plus aucun rafraîchissement, une valeur tournée
   au coffre n'arrive pas.
3. **Les Applications concernées passent `Degraded`** : ArgoCD embarque un health check pour ce
   type. Le mur vire au rouge alors que rien n'est cassé côté charge — c'est le signal que les
   secrets ne se rafraîchissent plus, pas une panne applicative.

⚠️ En `deletionPolicy: Delete`, le point 1 tomberait : un simple upgrade du chart openbao
couperait le SSO et Grafana. Ne jamais y toucher.

## Rotation

C'est le gain principal du canal openbao sur le scellement : **ni commit, ni `kubeseal`, ni
redéploiement**.

```bash
kubectl -n openbao exec -ti openbao-0 -- bao kv put kv/homelab/grafana/oidc client-secret=…
```

ESO reprend la valeur au prochain `refreshInterval` (1 h). Pour l'appliquer tout de suite :

```bash
kubectl -n monitoring annotate externalsecret grafana-oidc force-sync=$(date +%s) --overwrite
```

Le KV est en **v2**, donc versionné : un écrasement accidentel se rattrape par `bao kv rollback`.
Pour un `SealedSecret`, la même opération demande de renseigner le template en clair, sceller,
committer, pousser et attendre la sync.

## Portée d'accès

Un `ClusterSecretStore` étant cluster-scoped, **n'importe quel namespace peut le référencer**.
Un `ExternalSecret` posé n'importe où pourrait donc lire tout ce que la policy openbao autorise —
aujourd'hui l'ensemble de `kv/data/homelab/*`. Le rayon d'action n'est borné que par cette policy,
qui vit dans le repo Terraform.

ESO sait restreindre les namespaces autorisés, via `spec.conditions`
(`namespaces`, `namespaceSelector` ou `namespaceRegexes`) :

```yaml
spec:
  conditions:
    - namespaces: [argocd, authentik, monitoring, renovate]
  provider:
    vault:
      ...
```

**Non appliqué aujourd'hui** : le repo est la seule source d'`ExternalSecret` et rien n'en crée
hors GitOps, donc la contrainte n'ajoute pas de barrière réelle contre un attaquant déjà capable
de committer. Son intérêt est ailleurs — rendre explicite **dans Git** qui a le droit de lire le
coffre, au lieu de laisser l'information dans une policy d'un autre repo.

## Diagnostiquer

```bash
kubectl get externalsecrets -A                     # STATUS attendu : SecretSynced
kubectl get clustersecretstore openbao -o yaml     # status.conditions → Ready=True
kubectl -n monitoring describe externalsecret grafana-oidc
kubectl -n external-secrets logs deploy/external-secrets
```

| Message | Cause |
|---|---|
| `permission denied` | policy/role manquant côté openbao, ou mauvais mount pour ce cluster |
| `Vault is sealed` / `503` | coffre scellé — le desceller ([openbao](../cluster/infra/openbao/README.md)) |
| `connection refused` / timeout (spoke) | exposition du hub incomplète : Gateway, certificat ou DNS |
| `cannot get ClusterSecretStore` | le store n'est pas encore synchronisé (wave de ressource 1) |
| `already exists and is not managed` | `creationPolicy: Owner` sur un Secret livré par un chart — passer en `Merge` |

## Ce que le coffre ne servira jamais

Un secret dont **openbao ou ESO** a besoin pour fonctionner ne peut pas venir d'openbao. C'est la
règle anti-cycle de [regles-gitops.md](regles-gitops.md), et elle a un cas concret à venir : le
jour où le CronJob de snapshot poussera vers S3/MinIO, ses credentials devront être un
`SealedSecret` — sinon la sauvegarde du coffre dépend du coffre.
