# kube-prometheus-stack

## Rôle

Stack d'observabilité du cluster : Prometheus + Alertmanager + Grafana + prometheus-operator
(CRDs ServiceMonitor/PodMonitor) + node-exporter + kube-state-metrics. Grafana est exposé sur
`https://grafana.lan.wittner.tech` via `shared-gw` (listener `https-internal`),
authentifié par un **compte admin local** dont le mot de passe est porté par un
**SealedSecret**. Le **SSO authentik (OIDC)** reste écrit mais **commenté** (cf. § SSO).
Prometheus et Alertmanager restent internes (non exposés).

Ce composant porte aussi tout le **câblage Grafana des composants tiers** : datasource
**Loki**, dashboards maison, ServiceMonitors ArgoCD.

> [!WARNING]
> **Ni Loki ni Alloy ne sont déployés par ce dépôt.** La datasource Loki est bien déclarée dans
> `helm-values.yaml` (`url: http://loki-gateway.loki.svc.cluster.local`), et les dashboards de logs
> l'interrogent — mais aucun composant de `cluster/` ne pose ce service. Tant qu'il n'existe pas,
> le dashboard « Logs — applications » et la datasource restent **vides**, sans erreur visible
> ailleurs. Les mentions de `loki` et `alloy` ci-dessous décrivent donc un câblage **attendu**, pas
> un état.

## Fichiers

- `kube-prometheus-stack.app.yaml` — Application (archétype (b) : chart + `$values` +
  `manifests/`). `ServerSideApply=true` (CRDs volumineuses).
- `helm-values.yaml` — admin local via `existingSecret`, blocs OIDC Grafana (`envValueFrom` +
  `auth.generic_oauth`) **commentés**, PVCs (Prometheus / Alertmanager / Grafana),
  rétention Prometheus, datasource Loki (`additionalDataSources`), dossier Grafana des dashboards maison, relabeling
  `instance` du node-exporter, scrapes control-plane désactivés
- `manifests/namespace.yaml` — ns `monitoring`
- `manifests/grafana-httproute.yaml` — HTTPRoute Grafana → `shared-gw`
- `manifests/alertmanager-httproute.yaml` — HTTPRoute Alertmanager → `shared-gw`, listener
  `https-internal`. ⚠️ **Aucune authentification derrière** — cf. § Accès
- `manifests/grafana-admin.sealed.yaml` — `SealedSecret` `grafana-admin`, clés `admin-user` /
  `admin-password` : le **seul** identifiant d'accès à Grafana
- `manifests/grafana-oidc.externalsecret.yaml` — `ExternalSecret` `grafana-oidc`, clé
  `client-secret`. **Vestige de l'ancien canal de secrets externe : non référencé dans
  `kustomization.yaml`, et le `ClusterSecretStore` qu'il vise n'existe plus** (cf. § SSO)
- `manifests/grafana-admin.externalsecret.yaml` — même vestige pour le compte admin,
  **non référencé** : remplacé par le `SealedSecret` ci-dessus, les deux visent le même `Secret`
- `manifests/dashboard-machines.yaml` — dashboard « Machines — system » : vue d'ensemble en
  carrés (CPU, RAM, disque en alerte, température, scrape), charge, stockage, réseau, thermique,
  et quatre lignes de diagnostic repliées. ⚠️ **Il couvre TOUT le parc** — les 3 nœuds Talos
  (`job="node-exporter"`) et les machines hors cluster (`job="external-node"`, composant
  [hosts-monitoring](../hosts-monitoring/README.md)) — et ses variables n'ont donc **aucun filtre
  de job**, ce qui est son objet même. Il remplace `dashboard-talos-nodes.yaml` et
  `dashboard-machine-forge.yaml`, supprimés le 2026-09-11 ; porte la couche d'annotations
  « Déploiements ArgoCD » (tags `argocd`, `deploy`)
- `manifests/dashboard-stockage-cluster.yaml` — dashboard « Storage — cluster » : état des nœuds
  Kubernetes (kube-state-metrics) et VolumeGroups LVM d'OpenEBS. ⚠️ C'est ce qui a été **retiré**
  du dashboard ci-dessus parce que ça décrit le CLUSTER et non une machine. Ses variables sont
  **filtrées sur `job="node-exporter"`** — l'inverse du précédent, et pour la même raison :
  `lvm_*` n'existe que dans le cluster, donc y proposer une machine externe afficherait un
  dashboard entièrement vide, sans erreur

- `manifests/dashboard-argocd.yaml` — dashboard « GitOps — ArgoCD » : état sync/santé des
  Applications, synchronisations, réconciliation du contrôleur, repo-server Git, notifications,
  santé des composants. Variables Projet/Application, 3 couches d'annotations
  (`deployed` / `degraded` / `sync-failed`)
- `manifests/dashboard-ressources-{cluster,namespaces,workloads,pods}.yaml` — chaîne
  « Ressources » (CPU/mémoire : utilisation, requests, limits) à 4 granularités, reliés par le
  tag `ressources`
- `manifests/dashboard-ressources-volumes.yaml` — même famille, axe stockage : remplissage et
  inodes par PVC, projection avant saturation, pool LVM, cycle de vie PVC/PV
- `manifests/dashboard-logs.yaml` — dashboard « Logs — applications » (datasource
  **Loki**) : débit, niveaux, erreurs, conteneurs les plus bavards, journal
  filtrable
- `manifests/dashboard-velero.yaml` — dashboard « Backups — velero » : fraîcheur de la
  dernière sauvegarde planifiée, résultats et durées, tableau une ligne par sauvegarde, copie
  kopia des volumes, maintenance du dépôt, restaurations
- `manifests/dashboard-cnpg.yaml` — dashboard « PostgreSQL — cnpg » : état des `Cluster`,
  réplication, connexions, volumétrie, activité et cache, deadlocks et fichiers temporaires, âge
  des XID, checkpoints et WAL, santé de l'opérateur. Variables Base / Base de données
- `manifests/dashboard-cnpg-barman-plugin.yaml` — dashboard « Sauvegardes PostgreSQL —
  barman-cloud » : fraîcheur et fenêtre PITR, tableau une ligne par base et une ligne par CR
  `Backup`, archivage WAL, coût du sidecar. Pendant du dashboard velero pour la chaîne de
  sauvegarde des bases — les deux ne se recouvrent pas
- `manifests/dashboard-forgejo.yaml` — dashboard « Forge — forgejo » : version servie, dépôts /
  organisations / équipes, issues (tableau par dépôt), comptes et clés, files de webhooks et de
  miroirs, CPU / mémoire / ancienneté du processus. ⚠️ **La forge n'est plus dans ce cluster**
  ([archive/forgejo](../../../archive/forgejo/README.md)) : sa source est le `/metrics` externe
  `https://forgejo-metrics.lan.wittner.tech/metrics`, **scrapé avec authentification** par la
  `ScrapeConfig` de [forgejo-monitoring](../forgejo-monitoring/README.md) — pas ici. Les panneaux
  de PVC et de redémarrages ont disparu avec la bascule : kubelet et kube-state-metrics ne voient
  pas une machine Docker. Préfixe des métriques : `gitea_`, pas `forgejo_`.
  ⚠️ Depuis le 2026-09-11 il a une **seconde source**, `job="forgejo-db"` (section « Base de
  données » : `pg_up`, taille, connexions, transactions, cache, deadlocks, verrous). Les deux jobs
  ne se lisent PAS pareil — les `gitea_*` sont des jauges recomptées à chaque scrape, les
  `pg_stat_database_*` de vrais compteurs cumulés : `rate()` est absurde sur les premières et
  obligatoire sur les secondes. Il a aussi une section **Sauvegarde** qui lit `forgejo_backup_*`
  sur le job `external-node` — donc sur un scrape posé par [hosts-monitoring](../hosts-monitoring/README.md),
  pas par forgejo-monitoring : fraîcheur, résultat, **taille des deux artefacts, durée, occupation
  locale**, plus une table de détail. ⚠️ Cette section se vide si le scrape de `hosts-monitoring`
  tombe, alors que le reste du dashboard reste vert. ⚠️ La table n'est **pas un historique** :
  Prometheus ne peut pas en donner un sans une série par snapshot, donc une cardinalité sans fin.
  L'historique est le graphe d'âge, dont chaque dent de scie est une sauvegarde ; la liste réelle
  des snapshots restic se lit avec `forgejo-ctl snapshots` sur l'hôte

- `manifests/dashboard-alertes.yaml` — dashboard « Alerts — cluster » : tuiles critiques /
  warnings / pending / chaîne d'alerting, tableau des alertes **firing et pending** avec leur
  ancienneté, historique par alerte, courbe par sévérité. Variables Composant (CNPG / Forgejo /
  velero / openebs / chart) et Sévérité
- `manifests/alertmanager-smtp.sealed.yaml` — `SealedSecret` `alertmanager-smtp`, clés
  `username` / `password` du relais SMTP. Monté en volume par `alertmanagerSpec.secrets` :
  Alertmanager lit le mot de passe dans un **fichier**, jamais depuis sa config
  (cf. § Notification mail)
- `manifests/alertmanager-smtp.secret.example.yaml` — template **versionné et vide** du credential
  SMTP : la forme attendue, les noms de clés (⚠️ le nom de la clé est le nom du fichier monté) et
  les pièges. Le clair réel est gitignoré (`*.secret.yaml`)
- `manifests/alertmanager-smtp.externalsecret.yaml` — même vestige pour le credential SMTP,
  **non référencé** : remplacé par le `SealedSecret` ci-dessus, les deux visent le même `Secret`.
  Jamais activé
- `manifests/servicemonitors-argocd.yaml` — scrape des 5 composants ArgoCD
- `manifests/kustomization.yaml` — assemblage

## Contraintes

- Un fichier référencé mais absent casse `kustomize build` et met toute l'Application en erreur :
  garder la ligne **commentée** tant que le secret n'existe pas.
- **Le compte admin est le seul accès à Grafana** tant que le SSO est commenté : perdre son mot
  de passe, c'est perdre l'interface. Il vient du `SealedSecret`, donc de Git — il ne dépend donc
  d'aucun service tiers, mais il dépend de la clé privée du contrôleur
  [sealed-secrets](../../infra/sealed-secrets/README.md), seul état non reconstructible du cluster.
- Tout ServiceMonitor destiné à ce Prometheus doit porter le label
  `release: kube-prometheus-stack` (`serviceMonitorSelectorNilUsesHelmValues`) — vaut aussi pour
  [openebs-monitoring](../../infra/openebs-monitoring/README.md),
  [velero-monitoring](../../infra/velero-monitoring/README.md),
  [cnpg-monitoring](../cnpg-monitoring/README.md) et
  [forgejo-monitoring](../forgejo-monitoring/README.md).
- Grafana est en `deploymentStrategy: Recreate` : son PVC est RWO node-local, un rollout en
  rolling update produirait un double-mount.
- Ne pas mettre `disable_login_form: true` : le formulaire local est aujourd'hui le seul moyen
  de se connecter, et il resterait le break-glass même si le SSO était réactivé.
- Les trois morceaux du SSO (`envValueFrom`, `auth.generic_oauth`, la ligne
  `grafana-oidc.externalsecret.yaml` du `kustomization.yaml`) se décommentent **ensemble** :
  un provider OIDC sans `client_secret` fait démarrer Grafana en erreur.
- `defaultRules.disabled` est indexé par **nom de règle** : un renommage amont la réactive
  silencieusement, sans erreur Helm ni écart de sync ArgoCD. Revérifier ce bloc à chaque bump du
  chart — cf. [la règle `KubeClientCertificateExpiration`](#règle-kubeclientcertificateexpiration-désactivée-depuis-le-2026-09-15).

## Opérations

### Compte admin Grafana

Identifiant unique de l'interface : utilisateur **`admin`**, mot de passe porté par le
`SealedSecret` `grafana-admin` (`manifests/grafana-admin.sealed.yaml`), consommé par
`grafana.admin.existingSecret` dans `helm-values.yaml`.

Le canal est **sealed-secrets** : le mot de passe voyage dans Git sous forme chiffrée, il ne
dépend donc d'aucun service tiers à interroger au moment du besoin — ce qui compte pour la seule
porte d'entrée d'un outil qu'on ouvre justement quand le reste va mal.

Création / rotation, **depuis la racine du repo** (le `.secret.yaml` est gitignoré) :

```bash
# 1. Cert public du contrôleur (une fois ; pub-cert.pem est gitignoré)
kubeseal --fetch-cert --controller-name=sealed-secrets --controller-namespace=sealed-secrets \
  > pub-cert.pem

# 2. Template en clair — le mot de passe généré est celui qu'on tape ensuite dans Grafana
cat > cluster/app/kube-prometheus-stack/manifests/grafana-admin.secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: grafana-admin
  namespace: monitoring
type: Opaque
stringData:
  admin-user: admin
  admin-password: "$(openssl rand -base64 30)"
EOF

# 3. Sceller, supprimer le clair, committer
kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
  < cluster/app/kube-prometheus-stack/manifests/grafana-admin.secret.yaml \
  > cluster/app/kube-prometheus-stack/manifests/grafana-admin.sealed.yaml
rm cluster/app/kube-prometheus-stack/manifests/grafana-admin.secret.yaml
```

Deux pièges :

- **Le `SealedSecret` est chiffré pour le couple (`grafana-admin`, `monitoring`)** : le renommer
  ou le déplacer le rend indéchiffrable, il faut le resceller.
- **Changer le `Secret` ne change pas le compte déjà créé en base.** Grafana lit
  `admin-password` au **premier** démarrage ; ensuite le mot de passe vit dans sa base SQLite,
  sur le PVC. Après rotation, redémarrer ne suffit pas — forcer la valeur :
  ```bash
  kubectl -n monitoring exec deploy/kube-prometheus-stack-grafana -c grafana -- \
    grafana cli admin reset-admin-password "<nouveau mot de passe>"
  ```

### SSO — authentik (OIDC), DÉSACTIVÉ

Tout est écrit et **commenté** : le bloc `envValueFrom` et le bloc `auth.generic_oauth` de
`helm-values.yaml`, plus la ligne `grafana-oidc.externalsecret.yaml` de
`manifests/kustomization.yaml`. Les trois se décommentent **ensemble** — un provider OIDC sans
`client_secret` fait démarrer Grafana en erreur, et `envValueFrom` seul monte un `Secret`
inexistant.

Le Provider / Application / groupes côté authentik sont gérés en **Terraform** (autre repo).
Contrat : `clientID=grafana`, issuer `https://authentik.wittner.tech/application/o/grafana/`,
scopes `openid profile email groups`, redirect URI
`https://grafana.lan.wittner.tech/login/generic_oauth`.

Mapping des groupes (claim `groups`, cf. `role_attribute_path` dans `helm-values.yaml`) :
**`app-grafana-admin`** → rôle Admin, **`app-grafana-viewer`** → rôle Viewer, défaut Viewer.

Réactivation : décommenter les trois morceaux, **puis sceller le client-secret** — le canal
externe n'existe plus, `grafana-oidc.externalsecret.yaml` est un vestige inerte.

```bash
# 1. Renseigner le client-secret dans un template en clair (gitignoré), puis :
kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
  < cluster/app/kube-prometheus-stack/manifests/grafana-oidc.secret.yaml \
  > cluster/app/kube-prometheus-stack/manifests/grafana-oidc.sealed.yaml
rm cluster/app/kube-prometheus-stack/manifests/grafana-oidc.secret.yaml

# 2. Référencer le scellé dans kustomization.yaml, DANS LE MÊME COMMIT.
```

⚠️ Le fournisseur d'identité lui-même (authentik) est **archivé** : la réactivation suppose d'abord
d'en remonter un.

### Scrape d'ArgoCD

L'install upstream d'ArgoCD ne fournit aucun ServiceMonitor : ils sont déclarés ici
(`servicemonitors-argocd.yaml`, ns `monitoring`, scrape cross-namespace vers `argocd`) et **non**
dans `infra/argocd/manifests` — ce dossier sert aussi à l'apply manuel du bootstrap, qui tourne
avant l'existence de la CRD `ServiceMonitor`. Le panneau « Cibles de scrape » du dashboard ArgoCD
est le premier endroit à regarder si les graphes sont vides :

```bash
kubectl -n monitoring get servicemonitor          # les 5 SM argocd-*
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
# puis Status → Targets, ou : curl -s 'localhost:9090/api/v1/query?query=up{job=~"argocd-.*"}'
```

### Chaîne de dashboards « Ressources »

`cluster → namespaces → workloads → pods` : mêmes indicateurs (utilisation, requests, limits,
ratios) à quatre granularités, plus `volumes` sur l'axe stockage. Le menu déroulant en haut à
droite (tag commun `ressources`) navigue entre eux **en conservant période et variables** ;
les tables de synthèse sont cliquables vers le niveau suivant.

Deux pièges de lecture, traités dans les requêtes et rappelés dans les descriptions des
panneaux :

- **requests > limits est normal.** Un conteneur peut déclarer des requests sans limite (les
  static pods de `kube-system`, par exemple). Les deux totaux portent donc sur des ensembles de
  conteneurs différents. Les ratios, eux, ne comparent que les conteneurs qui déclarent la
  ressource, et une tuile « Conteneurs sans limite » chiffre l'écart.
- **Sur `workloads`, la variable Type vaut « All » par défaut** — sans quoi le total du
  dashboard ne correspond pas à celui du namespace : restreindre à `deployment` masque les
  static pods et les DaemonSets, c'est-à-dire l'essentiel de `kube-system`.

Sur `volumes`, les deux vues du remplissage ne se remplacent pas : les `kubelet_volume_stats_*`
disent ce que voit le filesystem de chaque PVC, la rangée pool LVM dit combien il reste
réellement côté Volume Group. C'est la seconde qui décide du moment où les écritures échouent.

Les requêtes s'appuient sur les **recording rules du chart** (`defaultRules`, actives par
défaut) : `node_namespace_pod_container:*`, `cluster:namespace:pod_*:active:*`,
`namespace_{cpu,memory}:*` et `namespace_workload_pod:kube_pod_owner:relabel`. Les désactiver
dans `helm-values.yaml` viderait ces dashboards.

À noter : le chart livre aussi ses propres dashboards « Kubernetes / Compute Resources »
(anglais, générés par kubernetes-mixin), qui couvrent un terrain proche. **Les deux familles
doivent afficher les mêmes chiffres** — si elles divergent, c'est un bug ici, et le suspect
numéro un est la façon d'interroger les règles amont. Deux conventions du mixin sont donc
reprises telles quelles :

- **CPU : `:sum_rate5m`, jamais `:sum_irate`.** Les deux règles existent, mais `irate` ne
  regarde que les deux derniers points. À un instant donné il affiche le pic de 30 s et non
  la charge moyenne ; sur un graphe dont le pas dépasse l'intervalle de scrape, les pointes
  sont sur-représentées au lieu d'être moyennées. Sur un nœud peu chargé, l'écart avec
  `rate5m` atteint couramment un facteur 2 à 3.
- **Mémoire : `max by (namespace, pod, container) (…{container!=""})`.** À la différence de
  la règle CPU, `node_namespace_pod_container:container_memory_working_set_bytes` n'agrège
  rien : elle conserve les labels `id`/`name` de cAdvisor. Après un redémarrage de conteneur,
  l'ancienne série reste exportée environ 5 minutes — sans ce `max`, `sum` compte le
  conteneur deux fois pendant ce laps de temps.

Même logique pour les métriques cAdvisor interrogées directement (throttling, CPU par pod du
dashboard ArgoCD) : toujours les qualifier par `job="kubelet", metrics_path="/metrics/cadvisor"`.
`container_cpu_usage_seconds_total` est aussi exposé par `/metrics/resource` du kubelet ; ce
endpoint n'est pas scrapé aujourd'hui (`kubelet.serviceMonitor.resource: false`, défaut du
chart), mais l'activer doublerait silencieusement toute requête non qualifiée.

Enfin, `increase()` et `rate()` prennent `$__rate_interval`, jamais `$__interval` : ce dernier
vaut le pas du panneau et peut descendre sous l'intervalle de scrape, auquel cas la fenêtre ne
contient pas deux points et le panneau reste vide sans lever d'erreur.

### Dossier Grafana « Wittnerlab »

Les dashboards maison portent l'annotation `grafana_folder: Wittnerlab` et atterrissent dans un
dossier dédié, listé **avant** les dashboards racine du chart. Le câblage est dans
`helm-values.yaml` (`sidecar.dashboards.folderAnnotation` + `provider.foldersFromFilesStructure`,
inséparables). Tout nouveau dashboard doit porter l'annotation, sinon il retombe à la racine avec
la trentaine de dashboards du chart.

### Convention d'écriture des dashboards (depuis le 2026-09-28)

Les 14 dashboards maison suivent le skill `grafana-dashboards`. Trois règles, vérifiables par
`lint_dashboard.py` du skill, qui sort **0 erreur** sur le dossier :

- **Tout le texte affiché est en ANGLAIS** — titre et description du dashboard, titres et
  descriptions de panneaux, `legendFormat`, textes de value mappings, labels de variables,
  `displayName` de colonnes. Les commentaires d'en-tête des fichiers et les README restent en
  français : ils documentent le dépôt, ils ne s'affichent pas dans Grafana.
  Deux exceptions, et ce sont des **valeurs de labels**, pas du texte de dashboard :
  `schedule="manuel"` (réécrit au scrape par le ServiceMonitor de `velero-monitoring`, et attendu
  tel quel par `prometheusrule.yaml`) et le label `disque` des métriques NVMe. Les traduire
  casserait les règles d'alerte et couperait les séries déjà stockées.
- **`timezone: "utc"`** partout, et non `browser`. Les horodatages affichés sont donc en UTC,
  décalés d'1 h ou 2 h par rapport à l'heure locale — c'est voulu : les cron des schedules
  (velero 03:00, cnpg 02:00) et les logs du cluster sont en UTC, et une lecture en heure locale
  obligeait à faire la conversion de tête à chaque incident.
- **`graphTooltip: 1`** (curseur partagé), `editable: true`, un `id` unique par panneau, une seule
  variable de datasource par dashboard (`DS_PROMETHEUS`, `DS_LOKI` pour les logs), et jamais d'uid
  de datasource en dur.

Les `uid` (`ressources-*`, `stockage-cluster`, `machines-systeme`, `cluster-alertes`) restent tels
quels : les renommer casserait toutes les URL déjà collées ailleurs. Les **tags** ont en revanche
été alignés (`ressources` → `resources`, `stockage` → `storage`, `alertes` → `alerts`), en même
temps que le `links[].tags` de la chaîne « Resources » qui s'appuie dessus.

### Redémarrages de conteneurs ≠ pods recréés

`kube_pod_container_status_restarts_total` ne compte QUE les redémarrages d'un conteneur **à
l'intérieur d'un pod qui continue d'exister**. Un pod recréé — rollout, éviction, drain — est un
nouvel objet dont le compteur repart à zéro : le panneau affiche 0 pendant précisément
l'événement qu'il est censé attraper. Les cinq panneaux concernés portent donc une seconde série,
`count(time() - kube_pod_start_time < fenêtre)`, qui compte les pods démarrés dans la fenêtre :

| Dashboard | Panneau |
|---|---|
| `Resources — cluster` | `Restarts / new pods (1 h)` |
| `Resources — pods` | `Container restarts and pod recreations` |
| `GitOps — ArgoCD` | `Container restarts and pod recreations` |
| `PostgreSQL — cnpg` | `Restarts / new pods in cnpg-system (24 h)` |
| `PostgreSQL backups — barman-cloud` | `barman-cloud container restarts and pod recreations` |

Le tableau « Per pod » de `Resources — pods` garde le compteur brut sans seconde série : il liste
les pods existants, un pod recréé y apparaît comme une ligne neuve.

### Logs — datasource Loki

La datasource `Loki` est déclarée dans `helm-values.yaml` (`grafana.additionalDataSources`), et
non côté composant **loki** : le câblage Grafana d'un composant tiers vit ici,
comme les dashboards et ServiceMonitors ArgoCD. Les logs sont collectés par
**alloy**. Vérification : Connections → Data sources → Loki → **Save & test**,
puis Explore avec une requête du type `{namespace="argocd"}`.

Le dashboard « Logs — applications » filtre par namespace / pod / conteneur, plus une variable
**Niveau** et une variable **Recherche** appliquée au contenu des lignes. Quatre choses à savoir
avant d'y toucher :

- **Écrire les regex entre backticks**, jamais entre guillemets. Entre guillemets, LogQL applique
  les échappements Go : `\b` devient un caractère backspace au lieu d'une limite de mot, et la
  requête — parfaitement valide — ne remonte plus rien. Un panneau vide, aucune erreur.
- Les niveaux viennent de **`detected_level`**, posé par Loki à l'ingestion : il lit le champ
  `level` d'une ligne JSON, le `level=` d'un logfmt, ou devine sur une ligne libre. Rien à
  configurer par application, et `warning` est normalisé en `warn`. Ce que Loki ne sait pas
  classer devient `unknown` — une application dont tout le volume est `unknown` gagnerait à
  émettre des logs structurés. Dépend de `discover_log_levels` côté **loki**.
- `detected_level` est une **métadonnée structurée**, pas un label : elle se filtre après le
  sélecteur (`| detected_level=~"…"`, jamais dans `{}`) et n'apparaît pas dans l'API des labels,
  d'où une variable `custom` et non un `label_values()`.
- Le filtre **Niveau n'agit que sur le panneau Logs**, volontairement : appliqué partout, il
  ferait afficher zéro à la tuile « Erreurs/s » dès qu'on sélectionne `info`.

### Objets exposés par kube-state-metrics

Trois familles de CRs sont converties en séries par `kube-state-metrics.customResourceState`
(`helm-values.yaml`) : `velero.io` (Backup, PodVolumeBackup) et `postgresql.cnpg.io`
(Cluster, Backup). Chaque famille demande **deux** blocs, et l'oubli du second est silencieux :

- `rbac.extraRules` — sans la règle `list`/`watch` sur le groupe d'API, KSM ne voit pas les CRs et
  les séries restent vides **sans erreur dans les logs**
- `customResourceState.config` — la définition des métriques

Pourquoi ce détour plutôt que les métriques natives : celles des composants décrivent la
**dernière** exécution (`velero_backup_tarball_size_bytes`,
`barman_cloud_cloudnative_pg_io_last_available_backup_timestamp`) et sont écrasées à chaque
passage. La liste des sauvegardes existantes est une propriété d'**objets** — KSM est le seul
chemin déclaratif vers un tableau « une ligne par sauvegarde ».

Deux pièges, tous deux vérifiés sur le cluster :

- **KSM n'ajoute pas le namespace de la CR.** Le label `namespace` des séries produites est celui
  du pod kube-state-metrics (`monitoring`), posé au relabeling. Les ressources CNPG déclarent donc
  un `db_namespace: [metadata, namespace]` explicite ; les séries velero, plus anciennes, ne
  l'ont pas et perdent l'information.
- **Deux sources ne nomment pas la même base pareil.** KSM étiquette `cnpg_cluster`
  (`labelsFromPath`), le collecteur d'instance étiquette `cnpg_io_cluster` (`podTargetLabels` du
  PodMonitor de [cnpg-monitoring](../cnpg-monitoring/README.md)). C'est délibéré — les deux
  sources n'ont ni la même fraîcheur ni la même sémantique, l'une survit à la mort de la base et
  l'autre non. Les requêtes qui les croisent passent par `label_replace` ; sans lui la jointure
  est vide, sans erreur.

Valider un changement de cette configuration **avant** de le pousser (une config refusée fait
planter KSM, donc tout le dashboarding cœur) :

```sh
yq '.["kube-state-metrics"].customResourceState.config' \
  cluster/app/kube-prometheus-stack/helm-values.yaml > /tmp/crs.yaml
kubectl config view --minify --flatten > /tmp/kubeconfig.yaml
docker run --rm -p 18081:8080 -v /tmp/crs.yaml:/crs.yaml -v /tmp/kubeconfig.yaml:/kubeconfig.yaml \
  registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.20.0 \
  --custom-resource-state-only --custom-resource-state-config-file=/crs.yaml \
  --kubeconfig=/kubeconfig.yaml
curl -s localhost:18081/metrics | grep '^cnpg_'
```

Le binaire ne valide la config qu'**après** avoir joint l'API : lancé sans cluster accessible, il
échoue sur la connexion avant d'avoir regardé le fichier. C'est pourquoi la commande ci-dessus
utilise le vrai kubeconfig — en lecture seule (`list`/`watch`).

### Dashboard « Alerts — cluster »

Vue unique sur les règles de tous les composants —
[cnpg-monitoring](../cnpg-monitoring/README.md),
[forgejo-monitoring](../forgejo-monitoring/README.md),
[velero-monitoring](../../infra/velero-monitoring/README.md),
[openebs-monitoring](../../infra/openebs-monitoring/README.md) et celles du chart. Il ne lit
**aucune** métrique d'application : uniquement `ALERTS` et `ALERTS_FOR_STATE`, synthétisées par
Prometheus. C'est délibéré — il reste lisible quand le composant surveillé est mort, ce qui est le
seul moment où on l'ouvre.

- **Pas de panneau « Alert list »** : il interroge un Alertmanager, or aucune datasource de ce
  type n'est déclarée dans `helm-values.yaml`. `ALERTS` s'en passe et donne en plus l'historique,
  qu'Alert list ne montre pas. Ajouter la datasource reste utile pour les **silences**, absents
  d'ici.
- **Le tableau montre `pending` autant que `firing`**, et c'est le choix qui le rend utile. Une
  règle passe `pending` dès que sa condition est vraie et n'atteint `firing` qu'après son `for:` —
  15 min pour la plupart, 1 h pour `CNPGBackupChainAbsent`. Limité à `firing`, le tableau restait
  vide pendant tout le quart d'heure suivant une panne, à côté d'une tuile affichant « 3 ».
- **Récupérer l'état dans le tableau demande un `group_left`** : `ALERTS_FOR_STATE` porte l'âge
  sans le label `alertstate`, `ALERTS` porte l'état sans l'âge. D'où
  `(time() - ALERTS_FOR_STATE) * ignoring(alertstate) group_left(alertstate) ALERTS` — la
  multiplication par 1 laisse l'âge intact et greffe le label.
- **La timeline code l'état dans la VALEUR** (`* 2` sur la branche firing → 1 = pending,
  2 = firing) : `ALERTS` vaut 1 dans les deux états, une bande unie ne distinguerait rien. Le
  `max by (alertname)` retire `alertstate` des labels, sans quoi chaque alerte occuperait deux
  lignes de l'axe Y.
- **`Watchdog` est exclu de tous les panneaux et remplacé par la tuile « Chaîne d'alerting »**
  (`absent(ALERTS{alertname="Watchdog"}) or vector(0)` → OK / MUETTE). Deadman switch du chart :
  il sonne en permanence, donc il occupait la seule ligne du tableau en temps normal et ajoutait
  aux graphes une série `severity=none` constamment à 1 qui décalait l'échelle. Son information
  est sa **disparition** — la tuile au rouge veut dire que Prometheus n'évalue plus, et qu'aucune
  autre tuile de la page n'est alors digne de confiance, y compris les vertes.
- **Le filtre Composant porte sur `alertname`, jamais sur `namespace`**, et ce n'est pas un
  raccourci : une règle bâtie sur `absent(...)` ne peut porter que les labels écrits dans ses
  matchers. `CNPGMetricsAbsent` et `ForgejoScrapeMissing` sortent ainsi **sans** label
  `namespace`. Un filtre par namespace en masquerait une partie sans rien signaler.
- **`ALERTS_FOR_STATE` n'a pas le label `alertstate`**, `ALERTS` l'a : d'où le
  `and ignoring(alertstate)` du tableau. Une jointure `on(alertname)` mélangerait deux instances
  d'une même règle ; sans `ignoring`, elle ne matche rien — tableau vide, aucune erreur.
- **`count()` sur vecteur vide ne rend pas 0, il ne rend rien** : les quatre tuiles portent
  `or vector(0)`, sans quoi « aucune alerte » s'afficherait « No data ».
- **`ALERTS` n'existe que pendant que l'alerte sonne** : une alerte résolue sort des graphes, et
  tout disparaît à 15 j (rétention). Ce dashboard n'est pas un journal d'incidents.
- **Il n'y a toujours aucune notification** : sans receiver Alertmanager, une alerte n'existe que
  si quelqu'un ouvre cette page.

### Notification mail des alertes critiques (ACTIF depuis le 2026-09-09)

Les trois morceaux sont en place et indissociables — les déplacer ensemble, toujours :

| Morceau | Où | Rôle |
| --- | --- | --- |
| `SealedSecret` `alertmanager-smtp` | `manifests/alertmanager-smtp.sealed.yaml` | porte le login et la clé SMTP |
| `alertmanagerSpec.secrets` | `helm-values.yaml` | monte le Secret sous `/etc/alertmanager/secrets/alertmanager-smtp/<clé>` |
| `alertmanager.config` | `helm-values.yaml` | route, inhibitions, receiver mail |

> [!WARNING]
> **L'ordre de pose n'est pas négociable, et son mode d'échec est muet.** Un volume dont le Secret
> manque laisse le pod Alertmanager en `ContainerCreating` **indéfiniment** — pas d'erreur de
> config, pas de `CrashLoopBackOff`, un pod qui ne démarre jamais. Le `SealedSecret` est donc
> référencé dans le **même commit** que le `secrets:` qui le monte. Retirer l'un des trois en
> laissant les autres reproduit exactement cette panne.

**Le canal est sealed-secrets** — `alertmanager-smtp.externalsecret.yaml` est conservé mais non
référencé, et le store qu'il visait n'existe plus. Ce n'est pas seulement une conséquence de
l'archivage : **faire dépendre l'alerting d'un service tiers le fait taire le jour où ce service
tombe** — et cette panne-là serait précisément **l'alerte qui ne part pas**. Même argument que pour
le compte admin Grafana (§ Compte admin Grafana), en plus fort : Alertmanager est l'outil qui doit
parler quand le reste se tait.

**Le credential est celui du mailer de Forgejo** (relais Brevo) : un seul relais, une seule clé.
⚠️ La tourner chez Brevo casse les **deux**. Depuis que la forge a quitté le cluster
([archive/forgejo](../../../archive/forgejo/README.md)), le second consommateur n'est plus un
fichier de ce dépôt mais le `[mailer]` de l'`app.ini` de sa machine Docker : une rotation demande
un resceller **ici** et une édition **là-bas**, et rien ne signale l'oubli du second — la forge
cesse simplement d'envoyer.

#### Ce qui part réellement en mail

Seul `severity = critical` est routé ; les `warning` restent dans Grafana. Ce n'est pas un filtre
arbitraire mais un **étagement** : l'échec ponctuel est un warning, sa persistance devient
critique, et c'est la persistance qui mérite un mail.

| Part en mail (`critical`) | Après | Reste dans Grafana (`warning`) |
| --- | --- | --- |
| `CNPGWalArchivingBacklog` | 30 m | `CNPGWalArchivingFailing` — l'échec, dont le backlog est la conséquence |
| `CNPGBackupTooOld` | 30 m | `CNPGLastBackupFailed` (15 m), `CNPGNoBackupYet` (24 h) |
| `CNPGBackupChainAbsent` | 1 h | |
| `CNPGMetricsAbsent` | 1 h | |
| `VeleroDown` | 15 m | `VeleroBackupFailed`, `VeleroBackupPartiallyFailed` |
| `VeleroBackupStorageLocationUnavailable` | 15 m | `VeleroNoBackupMetric` (6 h) |
| `VeleroBackupTooOld` | 30 m | `VeleroRepoMaintenanceFailing` |
| `VeleroNodeAgentNotReady` | 30 m | |

Chaque warning a son critical en aval : un archivage WAL qui échoue finit en backlog, une
sauvegarde qui rate finit en sauvegarde trop vieille. Rien d'important n'est muet — **sauf ce que
personne ne mesure**, à savoir la copie kopia étalée d'un PVC, qui produit une sauvegarde verte
(cf. [`doc/forgejo-pra.md`](../../../doc/forgejo-pra.md), écrit du temps où la forge était
sauvegardée ici). ⚠️ Le point a de nouveau un objet depuis le **2026-09-23** : une schedule quotidienne tourne sur
le namespace `hermes` — cf. [velero](../../infra/velero/README.md). C'est précisément le cas que
le hook `hermes backup` doit couvrir, et il n'est pas encore posé : la copie kopia d'un `state.db`
vivant est cohérente-CRASH.

#### Éprouvé le 2026-09-09 — bout en bout, mails reçus

La chaîne a été prouvée **entière**, injection → relais → boîte, et pas seulement « la config est
chargée ». Les deux points qui ne se vérifiaient pas depuis le dépôt sont donc fermés :

| Point | Résultat |
| --- | --- |
| `smtp_from: alertmanager@wittner.tech` | **validé** — le domaine `wittner.tech` est bien authentifié chez Brevo, pas seulement `forgejo@`. Aucun repli nécessaire |
| Envoi réel | mail `[FIRING]` reçu, puis `[RESOLVED]` à l'expiration — `send_resolved` prouvé aussi |

**La méthode retenue n'est pas celle qui était prévue.** Le reroutage temporaire du `Watchdog`
demandait deux commits et un aller-retour ArgoCD. Injecter une alerte à la main ne touche ni Git ni
l'état durable — c'est un **événement**, au sens de la règle de [`doc/`](../../../doc/README.md) —
et elle s'éteint seule. À rejouer tel quel après toute modification du bloc `config` :

```bash
kubectl -n monitoring exec alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- \
  amtool alert add \
    --alertmanager.url=http://127.0.0.1:9093 \
    alertname=TestNotificationMail \
    severity=critical \
    namespace=monitoring \
    --annotation=summary='Test manuel de la chaîne de notification' \
    --annotation=description='Alerte injectée à la main. Aucune panne réelle.'
```

Elle matche `severity = "critical"` → `email-critique`, et ni la route `Watchdog` ni aucune règle
d'inhibition. Déroulé mesuré : mail `[FIRING]` **~30 s** après (le `group_wait`), mail `[RESOLVED]`
**~5 min** après (l'alerte expire d'elle-même sur `resolve_timeout`). Rien à nettoyer.

> [!WARNING]
> **Un envoi réussi ne laisse AUCUNE trace dans les logs.** Relevé le 2026-09-09 : `logLevel: info`,
> **zéro ligne** sur les 45 minutes couvrant les deux envois. `Notify success` est journalisé en
> `debug`, pas en `info` — attendre cette ligne fait conclure à tort que la chaîne est morte.
>
> Corollaire, et c'est le vrai piège : **les logs ne servent qu'au diagnostic d'échec.** La seule
> preuve qu'un mail est parti est le mail lui-même.

Ce que les logs disent quand ça rate, en revanche :

| Log | Cause |
| --- | --- |
| `Invalid username or password` / `535` | credential Brevo faux, ou `smtp_auth_username` renseigné avec l'adresse du compte au lieu de l'identifiant `<id>@smtp-brevo.com` |
| `i/o timeout` / `connection refused` | sortie vers `smtp-relay.brevo.com:587` bloquée |
| **rien**, et pas de mail non plus | l'alerte n'a pas atteint le receiver : routage, pas SMTP. Vérifier `/#/status` |
| **rien**, mais mail attendu jamais reçu | ⚠️ le cas vicieux : le relais a **accepté puis jeté**. Ne se diagnostique que dans les logs d'envoi **côté Brevo**. C'est le symptôme d'un `smtp_from` non validé — écarté ici, mais il reviendrait au premier changement d'expéditeur |

#### Ce que ce câblage décide, et qui se relit dans les commentaires du bloc

- **`config` REMPLACE la configuration par défaut du chart, elle ne s'y ajoute pas.** Les
  `inhibit_rules` recopiées sont celles du chart : sans elles, un composant en `critical` enverrait
  aussi ses `warning` — plusieurs mails pour une seule panne.
- **`Watchdog` est explicitement routé vers `"null"`** : il sonne toujours, il produirait une
  notification toutes les 4 h à vie. Sa valeur est de disparaître, ce qu'un mail ne peut pas dire —
  seul un service externe (healthchecks.io et consorts) peut surveiller ce silence, **et rien ne le
  fait aujourd'hui**.

> [!CAUTION]
> **Ce câblage ne couvre pas sa propre panne.** Si Prometheus ou Alertmanager tombe, aucun mail ne
> partira — y compris pour signaler qu'ils sont tombés. C'est la limite structurelle du deadman
> switch routé vers `"null"` : le seul détecteur possible est hors du cluster, et il n'existe pas.

- **`repeat_interval: 4h`** au lieu des 12 h du chart : une panne du soir ne doit pas attendre le
  matin pour son premier rappel.
- **`smtp_auth_password_file`, jamais `smtp_auth_password`** : le mot de passe vient du volume, ce
  qui garde `helm-values.yaml` publiable. Le login, lui, est en clair — Alertmanager n'a pas de
  `smtp_auth_username_file`. Il est malgré tout scellé à côté du mot de passe, pour que la paire ne
  se dissocie jamais.
- **Le nom de la clé du Secret EST le nom du fichier monté.** Renommer `password` casse le chemin
  `smtp_auth_password_file` — sans autre signal qu'un échec d'envoi au premier mail.
- **`tplConfig: false`** dans ce chart (revérifié en **88.6.5** au rendu) : les `{{ }}` du `Subject`
  partent tels quels vers Alertmanager. Si ce flag passait à `true`, Helm les interpréterait
  d'abord et le sujet arriverait vide — il faudrait les échapper.

### Règle `KubeClientCertificateExpiration` désactivée (depuis le 2026-09-15)

Elle sonnait en `critical` sur les deux apiservers (`192.168.1.11`, `192.168.1.12`) sans
interruption. `defaultRules.disabled` dans `helm-values.yaml` la coupe — **les deux variantes**,
warning 7 j et critical 24 h, partagent ce nom.

**Elle ne mesure pas ce que son résumé annonce.** Son expression ne lit aucune date d'expiration :

```promql
histogram_quantile(0.01, sum without (namespace, service, endpoint) (rate(apiserver_client_certificate_expiration_seconds_bucket{job="apiserver"}[5m]))) < 86400
and
on (job, cluster, instance) apiserver_client_certificate_expiration_seconds_count{job="apiserver"} > 0
```

C'est le **1er centile** de la vie restante des certificats présentés dans les 5 dernières
minutes. Le `sum without (...)` conserve le label `instance` : le centile est calculé **par
apiserver**, d'où deux alertes distinctes pour une seule cause. Or `histogram_quantile` interpole **à l'intérieur du premier bucket** : dès qu'une
observation tombe dans `le="0"` — certificat que l'apiserver ne sait pas parser, requête arrivant
par l'aggregator — le centile s'écrase vers 0 et y reste. La règle passe alors `firing` en
permanence, indépendamment de l'état réel des certificats. Un seul client marginal suffit ; il n'y
a pas de seuil à remonter qui rende la mesure juste.

**Les certificats ont été vérifiés un par un avant de couper.** Tous émis au bootstrap du
2026-08-29, tous valables jusqu'au 2027-08-29 :

| Client | Emplacement | Sujet |
| --- | --- | --- |
| kubelet | `/var/lib/kubelet/pki/kubelet-client-current.pem` | `O=system:nodes` |
| controller-manager | `/system/secrets/kubernetes/kube-controller-manager/kubeconfig` | `O=system:kube-controller-manager` |
| scheduler | `/system/secrets/kubernetes/kube-scheduler/kubeconfig` | `O=system:kube-scheduler` |
| admin | kubeconfig local | `O=system:masters` |

Aucun sous 24 h, aucun sous 7 j. L'alerte était fausse **par construction**, pas en avance.

**Ce qu'on perd, et comment on le compense.** Un certificat client réellement mourant ne déclenche
plus rien. La compensation n'est pas un composant de plus mais un contrôle manuel, à passer avant
chaque anniversaire de bootstrap (**échéance : 2027-08-29**) — depuis le dépôt `homelab_talos` :

```bash
# Certificat client du kubelet
talosctl --talosconfig=./clusterconfig/talosconfig -n 192.168.1.11 \
  read /var/lib/kubelet/pki/kubelet-client-current.pem \
  | openssl x509 -noout -subject -startdate -enddate

# Kubeconfigs générés par Talos pour le control-plane
for c in kube-controller-manager kube-scheduler; do
  echo "=== $c ==="
  talosctl --talosconfig=./clusterconfig/talosconfig -n 192.168.1.11 \
    read /system/secrets/kubernetes/$c/kubeconfig \
    | yq -r '.users[0].user."client-certificate-data"' | base64 -d \
    | openssl x509 -noout -subject -startdate -enddate
done

# Kubeconfig admin local
kubectl config view --raw \
  -o jsonpath='{.users[?(@.name=="admin@bleu-kalecgos")].user.client-certificate-data}' \
  | base64 -d | openssl x509 -noout -subject -startdate -enddate
```

Sur Talos ces certificats sont émis et rotés par la machine elle-même : leur échéance relève de
`talosctl`, pas d'une métrique de l'apiserver. Renouvellement par `talosctl kubeconfig --force`
pour l'admin, par la rotation Talos pour les autres.

**Si l'alerte devait revenir** — parce qu'un `defaultRules.disabled` a sauté à un bump de chart —
la requête qui tranche vrai/faux positif est la répartition des buckets :

```promql
sum by (le) (rate(apiserver_client_certificate_expiration_seconds_bucket{job="apiserver"}[5m]))
```

`le="0"` nourri et constant → artefact. `le="86400"` qui se remplit progressivement alors que
`le="0"` reste vide → certificat réellement en fin de vie, et là il faut agir.

### Accès Prometheus / Alertmanager

**Alertmanager est exposé sur le LAN** : `https://alertmanager.lan.wittner.tech`
(`manifests/alertmanager-httproute.yaml`, listener `https-internal` du `shared-gw`, wildcard
`*.lan.wittner.tech`). Aucun port ouvert sur Internet — le listener `https-public` n'est pas visé
et le tunnel Cloudflare ne connaît pas ce hostname.

> [!CAUTION]
> **Cette URL n'est protégée par rien.** Alertmanager n'a pas d'authentification, l'opérateur n'en
> propose pas, et l'implémentation Gateway API de Cilium non plus. Quiconque l'atteint depuis le
> LAN peut **créer un silence**, c'est-à-dire éteindre la surveillance des sauvegardes — sans
> identifiant et sans trace attribuable.
>
> C'est l'asymétrie avec Grafana, qui est sur le même listener mais derrière un compte
> (`grafana-admin`). Le risque est assumé pour ce que la route apporte : poser un silence **avant**
> une opération planifiée, et rendre cliquable le bouton « View In Alertmanager » des mails depuis
> n'importe quel appareil du LAN. En faire une URL authentifiée demanderait un proxy d'auth, donc
> un logiciel de plus.

> [!WARNING]
> **Le hostname doit aussi être déclaré sur le reverse proxy LAN (192.168.1.50), hors de ce
> dépôt.** Sans cette déclaration, la réponse est **404 alors que l'`HTTPRoute` est sain** — le
> symptôme ne pointe pas vers sa cause.

**Prometheus reste non exposé**, et c'est délibéré : il n'a aucun usage à distance comparable à la
pose d'un silence, et il divulguerait toute la topologie et la volumétrie du homelab à qui atteint
l'URL. Son `externalUrl` vaut donc `http://localhost:9090` — le lien « Source » des mails devient
cliquable exactement quand le port-forward est ouvert, c'est-à-dire quand on diagnostique.

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093   # secours
```

⚠️ **Le port 9090 de la première commande est load-bearing** : c'est celui qu'attend le lien
« Source » des mails. Le changer casse ces liens, sans autre signal.

> [!NOTE]
> **Ce défaut ne se voyait qu'en lisant un vrai mail.** Sans `externalUrl`, l'opérateur y met le
> DNS interne du cluster (`http://kube-prometheus-stack-alertmanager.monitoring:9093`), qui ne
> résout nulle part depuis un client mail. Aucun contrôle en cluster ne le montre : les objets sont
> sains, les alertes partent, seuls les liens sont morts. Constaté le 2026-09-09 en lisant le mail
> d'un exercice d'injection, pas en relisant la configuration.

### État

```bash
kubectl -n monitoring get pods
kubectl -n monitoring get pvc
kubectl get crd | command grep monitoring.coreos.com
```
