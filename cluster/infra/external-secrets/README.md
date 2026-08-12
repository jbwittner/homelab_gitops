# external-secrets

## Rôle

Pont entre [openbao](../openbao/README.md) et Kubernetes : lit les secrets du coffre et les
matérialise en `Secret` natifs, que les composants consomment sans rien savoir de leur origine.
C'est le **second canal de secrets** du repo, à côté de
[sealed-secrets](../sealed-secrets/README.md) — critère de choix entre les deux :
[doc/regles-gitops.md](../../../doc/regles-gitops.md).

Déployé sur le **hub uniquement** (`Application`) : c'est le seul cluster qui consomme des secrets
du coffre aujourd'hui. Un `Secret` Kubernetes ne traversant pas les clusters, le jour où un spoke
en consommera il lui faudra son propre contrôleur — donc une migration en `ApplicationSet`
(cf. § Étendre à un second cluster).

## Fichiers

- `external-secrets.app.yaml` — `Application`, wave `-7`, destination `bleu-kalecgos`
- `helm-values.yaml` — CRDs par le chart, RBAC `serviceaccounts/token`, cache de tokens,
  ServiceMonitor
- `manifests/namespace.yaml` — ns `external-secrets` (wave -1), sans label PodSecurity
- `manifests/clustersecretstore-openbao.yaml` — le `ClusterSecretStore` `openbao`, en accès
  intra-cluster
- `manifests/kustomization.yaml` — les deux ci-dessus, sans champ `namespace:` (ressources
  cluster-scoped)

## Le store

| | `bleu-kalecgos` (hub) |
|---|---|
| `server` | `http://openbao.openbao.svc.cluster.local:8200` — intra-cluster |
| `mountPath` | `kubernetes-bleu-kalecgos` |
| Prérequis côté openbao | mount local |

Le **nom du store est `openbao`**, et ce n'est pas décoratif : les `ExternalSecret` des composants
le référencent sans savoir sur quel cluster ils tournent, ce qui rendrait un composant déplaçable
d'un cluster à l'autre sans retoucher ses secrets. Conserver ce nom sur tout futur cluster.

## Étendre à un second cluster

Un spoke qui consomme un secret du coffre a besoin de **son propre contrôleur ESO** : un `Secret`
Kubernetes ne traverse pas les clusters. Ce composant repasse alors en `ApplicationSet`
(cf. [doc/conventions.md](../../../doc/conventions.md)) — `helm-values.yaml` et
`manifests/namespace.yaml` vont dans `common/`, le store dans `<cluster>/manifests/`. Deux
différences pour un spoke, toutes deux dues au fait que le coffre vit sur le hub :

- `server` : `https://openbao.lan.wittner.tech` (via `shared-gw`), `openbao.openbao.svc` ne
  résolvant pas depuis un spoke. Dépendance de bootstrap qui n'existe pas ici : Gateway
  programmée, certificat wildcard émis, DNS résolu.
- mount d'auth `kubernetes-<cluster>`, à configurer côté openbao avec le `kubernetes_host`, le
  `kubernetes_ca_cert` et un `token_reviewer_jwt` **du spoke** — openbao n'a aucun accès local à
  son API TokenReview.

⚠️ La migration **renomme** l'Application (`external-secrets` → `bleu-kalecgos-external-secrets`).

## Contraintes

- **Un mount d'auth par cluster, ce n'est pas un choix de style.** Une méthode d'auth
  `kubernetes` d'openbao est configurée pour **un** API server (issuer, CA, TokenReview) : un
  mount unique partagé ne saurait pas valider les tokens d'un autre cluster.
- **L'auth ne consomme aucun secret.** ESO forge un token pour son propre ServiceAccount via
  l'API TokenRequest. C'est ce qui permet d'introduire ce composant **sans ajouter de
  SealedSecret**, et donc de descendre le repo à un seul scellé. Corollaire :
  `rbac.serviceAccountTokenCreate` est load-bearing, à `false` tous les `ExternalSecret`
  restent `NotReady`.
- **`deletionPolicy: Retain` sur tous les `ExternalSecret`.** OpenBao redémarre **scellé** : à
  chaque redémarrage de son pod, le store devient injoignable. En `Retain`, les `Secret` déjà
  matérialisés survivent et les applications continuent de tourner ; en `Delete`, un simple
  upgrade du chart openbao couperait le SSO, Grafana et Renovate.
- **Une Application dont un `ExternalSecret` est en erreur passe `Degraded`.** ArgoCD embarque
  un health check pour ce type. Coffre scellé ⇒ les composants concernés virent au rouge alors
  que les charges tournent normalement. Signal correct, mais à savoir lire.
- **La wave `-7` est de nouveau ordonnante.** Sous forme d'`ApplicationSet`, elle portait sur
  l'appset et non sur les Applications générées : la présence des CRDs avant le premier
  `ExternalSecret` du repo (celui de `cert-manager-config`, wave `-4`) n'était qu'*éventuelle*.
  Le tier-2 `infra` synchronisant désormais l'Application elle-même, l'ordre est **garanti**.
- **Les CRDs arrivent avant le premier `ExternalSecret`, le coffre non.** La wave `-7` garantit
  que les manifestes se rendent, pas qu'ils se résolvent : openbao est en wave `1` et se descelle
  à la main. Tout `ExternalSecret` posé en wave négative — `cert-manager-config` (`-4`),
  `argocd` (`-1`) — est donc `NotReady` par construction au bootstrap à froid, jusqu'au
  descellement.
- **La config du coffre n'est pas dans ce repo.** Le store suppose côté openbao un moteur KV
  v2 sur `kv`, le mount d'auth du cluster, un role `external-secrets` borné au ServiceAccount du
  même nom, et une policy en lecture sur `kv/data/homelab/*`. Ce contrat vit dans le repo
  Terraform. Rien ici ne le vérifie : s'il manque, les `ExternalSecret` échouent en
  `permission denied`.
- **ServiceMonitor.** `renderMode: skipIfMissing` : le template est omis là où la CRD
  `ServiceMonitor` n'existe pas — au tout premier bootstrap, ESO (wave `-7`) précédant
  kube-prometheus-stack. ArgoCD cachant le rendu, un **Hard Refresh** est nécessaire pour voir
  la cible apparaître après coup.

## Opérations

- **Inventaire des secrets servis** :
  ```bash
  kubectl get externalsecrets -A
  ```
- **État de l'Application** :
  ```bash
  kubectl -n argocd get app external-secrets
  ```
- **Diagnostiquer un `ExternalSecret` en échec** — la cause est dans les conditions :
  ```bash
  kubectl -n monitoring describe externalsecret grafana-oidc
  kubectl -n external-secrets logs deploy/external-secrets
  ```
  | Message | Cause |
  |---|---|
  | `permission denied` | policy/role manquant côté openbao, ou mauvais mount |
  | `Vault is sealed` / `503` | coffre scellé — le desceller (cf. [openbao](../openbao/README.md)) |
  | `cannot get ClusterSecretStore` | le store n'est pas encore synchronisé (wave 1) |
- **Vérifier l'état du pont** :
  ```bash
  kubectl get clustersecretstore openbao -o yaml     # status.conditions → Ready=True
  ```
- **Forcer un rafraîchissement immédiat** (sans attendre le `refreshInterval` d'1 h), après une
  rotation au coffre :
  ```bash
  kubectl -n monitoring annotate externalsecret grafana-oidc force-sync=$(date +%s) --overwrite
  ```
- **Upgrade** : bumper `targetRevision` dans `external-secrets.app.yaml`. Les CRDs sont livrées
  par le chart, donc mises à jour avec.
