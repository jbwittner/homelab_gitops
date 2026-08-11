# kube-prometheus-stack

## Rôle

Stack d'observabilité du cluster : Prometheus + Alertmanager + Grafana + prometheus-operator
(CRDs ServiceMonitor/PodMonitor) + node-exporter + kube-state-metrics. Grafana est exposé sur
`https://grafana.lan.wittner.tech` via `shared-gw` (listener `https-internal-kalecgos`),
en **SSO authentik (OIDC)** avec **login local conservé** en break-glass. Prometheus et
Alertmanager restent internes (non exposés).

Ce composant porte aussi tout le **câblage Grafana des composants tiers** : datasource
[Loki](../loki/README.md), dashboards maison, ServiceMonitors ArgoCD.

## Fichiers

- `kube-prometheus-stack.app.yaml` — Application (archétype (b) : chart + `$values` +
  `manifests/`). `ServerSideApply=true` (CRDs volumineuses).
- `helm-values.yaml` — OIDC Grafana (`auth.generic_oauth`), mapping groupe → rôle, admin local
  via `existingSecret`, PVCs (Prometheus / Alertmanager / Grafana), rétention Prometheus,
  datasource Loki (`additionalDataSources`), dossier Grafana des dashboards maison, relabeling
  `instance` du node-exporter, scrapes control-plane désactivés
- `manifests/namespace.yaml` — ns `monitoring`
- `manifests/grafana-httproute.yaml` — HTTPRoute Grafana → `shared-gw`
- `manifests/grafana-oidc.sealed.yaml` — SealedSecret `grafana-oidc`, clé `client-secret`
- `manifests/grafana-admin.sealed.yaml` — SealedSecret `grafana-admin`, clés `admin-user` /
  `admin-password` (break-glass)
- `manifests/dashboard-talos-nodes.yaml` — dashboard « Système — nœuds Talos » (sidecar, label
  `grafana_dashboard: "1"`) ; porte la couche d'annotations « Déploiements ArgoCD » (tags
  `argocd` + `deployed`, cf. [argocd](../../infra/argocd/README.md))
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
  [Loki](../loki/README.md)) : débit, niveaux, erreurs, conteneurs les plus bavards, journal
  filtrable
- `manifests/servicemonitors-argocd.yaml` — scrape des 5 composants ArgoCD
- `manifests/kustomization.yaml` — assemblage

## Contraintes

- Un `*.sealed.yaml` référencé mais absent casse `kustomize build` et met toute l'Application en
  erreur : garder la ligne **commentée** tant que le secret n'est pas scellé.
- Tout ServiceMonitor destiné à ce Prometheus doit porter le label
  `release: kube-prometheus-stack` (`serviceMonitorSelectorNilUsesHelmValues`) — vaut aussi pour
  [loki](../loki/README.md), [alloy](../alloy/README.md) et [openebs](../../infra/openebs/README.md).
- Grafana est en `deploymentStrategy: Recreate` : son PVC est RWO node-local, un rollout en
  rolling update produirait un double-mount.
- Ne pas mettre `disable_login_form: true` : le formulaire local est le break-glass si authentik
  est indisponible.

## Opérations

### SSO — authentik (OIDC)

Le Provider / Application / groupes côté authentik sont gérés en **Terraform** (autre repo).
Contrat : `clientID=grafana`, issuer `https://authentik.wittner.tech/application/o/grafana/`,
scopes `openid profile email groups`, redirect URI
`https://grafana.lan.wittner.tech/login/generic_oauth`.

Mapping des groupes (claim `groups`, cf. `role_attribute_path` dans `helm-values.yaml`) :
**`app-grafana-admin`** → rôle Admin, **`app-grafana-viewer`** → rôle Viewer, défaut Viewer.
Compte local `admin` (secret `grafana-admin`) conservé en break-glass.

### Câblage des secrets

Commandes **depuis la racine du repo** ; les `*.secret.yaml` sont gitignorés.

```bash
# 1. Renseigner les templates locaux :
#    cluster/app/kube-prometheus-stack/manifests/grafana-oidc.secret.yaml  → client-secret (output terraform)
#    cluster/app/kube-prometheus-stack/manifests/grafana-admin.secret.yaml → admin-user / admin-password
#      (mot de passe : openssl rand -base64 30)

# 2. Sceller, puis supprimer les fichiers en clair
kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
  < cluster/app/kube-prometheus-stack/manifests/grafana-oidc.secret.yaml \
  > cluster/app/kube-prometheus-stack/manifests/grafana-oidc.sealed.yaml
kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
  < cluster/app/kube-prometheus-stack/manifests/grafana-admin.secret.yaml \
  > cluster/app/kube-prometheus-stack/manifests/grafana-admin.sealed.yaml
rm cluster/app/kube-prometheus-stack/manifests/grafana-{oidc,admin}.secret.yaml

# 3. Commit + push (les 2 lignes *.sealed.yaml sont déjà dans kustomization.yaml).
```

Rotation : régénérer côté Terraform (OIDC) ou `openssl` (admin), re-renseigner le template,
re-sceller (étape 2).

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

### Logs — datasource Loki

La datasource `Loki` est déclarée dans `helm-values.yaml` (`grafana.additionalDataSources`), et
non côté composant [loki](../loki/README.md) : le câblage Grafana d'un composant tiers vit ici,
comme les dashboards et ServiceMonitors ArgoCD. Les logs sont collectés par
[alloy](../alloy/README.md). Vérification : Connections → Data sources → Loki → **Save & test**,
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
  émettre des logs structurés. Dépend de `discover_log_levels` côté [loki](../loki/README.md).
- `detected_level` est une **métadonnée structurée**, pas un label : elle se filtre après le
  sélecteur (`| detected_level=~"…"`, jamais dans `{}`) et n'apparaît pas dans l'API des labels,
  d'où une variable `custom` et non un `label_values()`.
- Le filtre **Niveau n'agit que sur le panneau Logs**, volontairement : appliqué partout, il
  ferait afficher zéro à la tuile « Erreurs/s » dès qu'on sélectionne `info`.

### Accès Prometheus / Alertmanager (non exposés)

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093
```

### État

```bash
kubectl -n monitoring get pods
kubectl -n monitoring get pvc
kubectl get crd | command grep monitoring.coreos.com
```
