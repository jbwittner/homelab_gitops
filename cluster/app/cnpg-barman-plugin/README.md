# cnpg-barman-plugin

## Rôle

Plugin **CNPG-I `barman-cloud`** : la sauvegarde native des bases [cnpg](../cnpg/README.md) vers un
stockage objet — sauvegardes de base **cohérentes-transaction** et **archivage WAL continu**, donc
PITR.

Composant séparé de `cnpg` parce que l'amont l'a séparé : depuis CloudNativePG **1.26**, le support
barman-cloud a été **sorti de l'opérateur** (`spec.backup.barmanObjectStore` déprécié puis retiré)
au profit d'un plugin distribué comme un chart et deux images à part. Deux charts, deux cadences de
release, deux `targetRevision` suivis séparément par Renovate → deux Applications.

> [!IMPORTANT]
> **Ce composant n'active aucune sauvegarde.** Il installe la mécanique et la CRD `ObjectStore`.
> Une base n'est prise en charge que si son `Cluster` porte explicitement `spec.plugins` — même
> logique de **liste blanche** que la schedule [velero](../../infra/velero/README.md). Aujourd'hui :
> `forgejo-db` seule. `authentik-db` et `pgsql-test` n'ont **aucune** chaîne de sauvegarde.

## Fichiers

- `cnpg-barman-plugin.app.yaml` — Application (archétype (a) : Helm + `$values`), ns `cnpg-system`,
  **wave `-1`**
- `helm-values.yaml` — Deployment du plugin uniquement : ressources, contextes de sécurité, CRD.
  Aucune configuration de bucket n'y vit

## Contraintes

- **Le plugin DOIT tourner dans le namespace de l'opérateur** (`cnpg-system`) : c'est là que
  l'opérateur cherche le Service `barman-cloud:9090` de CNPG-I. Le déplacer ne produit aucune
  erreur de déploiement — seulement des `Cluster` dont le plugin reste injoignable.
- **Le nom du Service `barman-cloud` est câblé en dur dans les certificats.** Le values.yaml amont
  le dit en capitales : le nom DNS du certificat serveur en dérive. Le renommer casse le mTLS
  opérateur ↔ plugin, et le symptôme est un plugin injoignable, pas une erreur de rendu.
- **Deux pré-requis, dont un cross-tier** :
  - CloudNativePG **≥ 1.26** — ici **1.30.0** (chart `cloudnative-pg` 0.29.0) ;
  - **cert-manager** — le chart rend un `Issuer` auto-signé et **deux** `Certificate` (client et
    serveur). cert-manager vit dans `cluster/infra/`, donc dans un autre app-of-apps : aucune wave
    ne les ordonne. Au bootstrap à froid l'Application reste en erreur jusqu'à son arrivée, puis se
    répare seule (`selfHeal`).
- **Wave `-1`, et elle est load-bearing.** Ce composant apporte la CRD
  `objectstores.barmancloud.cnpg.io`, consommée par le `manifests/` de
  [forgejo](../forgejo/README.md) (wave 0). Les deux vivant dans le **même** app-of-apps
  (`cluster/app/app.bootstrap.yaml`), la wave suffit à les ordonner — contrairement à la dépendance
  `forgejo → cnpg`, qui n'est que documentée.
- **`crds.create` reste à `true`.** ArgoCD rend le chart avec `--include-crds` : la CRD fait partie
  de l'ensemble désiré et est réconciliée à chaque sync. La couper en pensant « elle est déjà là »
  la ferait **sortir** de l'ensemble désiré, et `prune: true` la supprimerait — emportant tous les
  `ObjectStore` avec elle.
- **Deux images, solidaires.** Le chart tire `plugin-barman-cloud` (le Deployment) *et*
  `plugin-barman-cloud-sidecar` (injecté dans chaque pod d'instance PostgreSQL). Les deux prennent
  l'appVersion du chart : ne pas épingler `image.tag` / `sidecarImage.tag` séparément.
- **Le travail réel est fait par le sidecar, pas par ce Deployment.** Celui-ci n'est qu'un serveur
  gRPC de contrôle et ne transporte aucune donnée. Les ressources qui comptent (upload, compression)
  se règlent **par `ObjectStore`**, dans `spec.instanceSidecarConfiguration.resources`.

## Où vit la configuration d'une sauvegarde

Rien ici. Trois objets, dans le `manifests/` de l'application qui possède la base — pour `forgejo` :

| Objet | Fichier | Rôle |
| --- | --- | --- |
| `ObjectStore` | `forgejo-db-objectstore.yaml` | bucket, credentials, rétention |
| `Cluster.spec.plugins` | `forgejo-db.yaml` | **met la base sous archivage WAL continu** |
| `ScheduledBackup` | `forgejo-db-scheduledbackup.yaml` | sauvegardes de base quotidiennes |

Les trois sont indissociables : un `ObjectStore` sans `spec.plugins` est inerte et ne le dit pas ;
un `spec.plugins` sans `ScheduledBackup` archive des WAL que rien ne complète.

`ObjectStore` est **namespacé** et le plugin n'en lit que dans le namespace du `Cluster` : il ne se
mutualise pas entre applications. Chaque base ajoutée veut le sien, **et** son propre SealedSecret
(sealed-secrets chiffre pour le couple nom/namespace).

## Opérations

- **Vérifier le plugin** :
  ```bash
  kubectl -n cnpg-system rollout status deploy/plugin-barman-cloud
  kubectl -n cnpg-system get certificate            # barman-cloud-client, barman-cloud-server
  kubectl -n cnpg-system logs deploy/plugin-barman-cloud
  ```
  Des `Certificate` qui restent `False` = cert-manager absent ou en erreur : le plugin démarre
  quand même et reste injoignable.

- **Vérifier qu'une base est bien prise en charge** :
  ```bash
  # ⚠️ Le sidecar est un INIT-CONTAINER (sidecar natif Kubernetes, `restartPolicy: Always`), pas un
  # conteneur ordinaire. `.spec.containers` ne renvoie que `postgres` et donne l'impression qu'il
  # manque.
  kubectl -n forgejo get pod forgejo-db-1 \
    -o jsonpath='{range .spec.initContainers[*]}{.name}{"\n"}{end}'
  kubectl -n forgejo get cluster forgejo-db -o jsonpath='{.status.pluginStatus}' | jq
  ```
  `pluginStatus` doit lister `barman-cloud.cloudnative-pg.io` avec la capability
  `TYPE_INSTANCE_SIDECAR_INJECTION`.

- **Mettre une nouvelle base sous sauvegarde** — quatre gestes, dans cet ordre :
  1. bucket + compte de service côté repo **Terraform** (cf. §Contraintes de
     [forgejo](../forgejo/README.md) pour le contrat) ;
  2. `ObjectStore` + SealedSecret du credential dans le `manifests/` de l'application ;
  3. `spec.plugins` sur le `Cluster` — ⚠️ **recrée le pod d'instance, avec ~200 s de coupure
     SQL** : 180 s d'arrêt smart (`smartShutdownTimeout`, consommé en entier parce qu'un pool de
     connexions applicatif ne se ferme jamais tout seul) puis ~20 s de redémarrage. Le `Cluster`
     affiche « Primary instance is being restarted without a switchover » pendant tout ce temps —
     c'est attendu, pas une panne ;
  4. `ScheduledBackup`, puis ajouter la base à `CNPGBackupChainAbsent`
     ([cnpg-monitoring](../cnpg-monitoring/README.md)) — c'est la **seule** alerte à nommer les
     bases en dur, et sans ce geste un retrait futur de `spec.plugins` passerait inaperçu.

- **Upgrade** : bumper `targetRevision` dans `cnpg-barman-plugin.app.yaml`, commit, push. Renovate
  le suit (manager `argocd`, motif `*.app.yaml`).

## Non retenu

- **`spec.backup.barmanObjectStore` sur le `Cluster`** (support in-tree). Retiré de CloudNativePG
  depuis la 1.26. Il serait accepté par la CRD sur des versions plus anciennes et ne sauvegarderait
  rien ici.
- **Workload Identity** (`googleCredentials.gkeEnvironment: true`). Suppose un cluster GKE où
  l'authentification passe par le nœud. Ici c'est une clé JSON scellée, comme pour velero.
- **Un bucket par base.** `serverName` vaut le nom du `Cluster` quand il est omis : barman range
  déjà sous `<bucket>/<cluster>/`. Un bucket unique pour toutes les bases CNPG, distinct de celui
  de velero et de celui d'openbao.
