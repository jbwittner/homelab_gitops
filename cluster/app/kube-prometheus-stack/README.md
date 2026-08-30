# kube-prometheus-stack

## Rôle

Stack d'observabilité du cluster : Prometheus + Alertmanager + Grafana + prometheus-operator
(CRDs ServiceMonitor/PodMonitor) + node-exporter + kube-state-metrics. Grafana est exposé sur
`https://grafana.lan.wittner.tech` via `shared-gw` (listener `https-internal-kalecgos`),
authentifié par un **compte admin local** dont le mot de passe est porté par un
**SealedSecret**. Le **SSO authentik (OIDC)** reste écrit mais **commenté** (cf. § SSO).
Prometheus et Alertmanager restent internes (non exposés).

Ce composant porte aussi tout le **câblage Grafana des composants tiers** : datasource
[Loki](../loki/README.md), dashboards maison, ServiceMonitors ArgoCD.

## Fichiers

- `kube-prometheus-stack.app.yaml` — Application (archétype (b) : chart + `$values` +
  `manifests/`). `ServerSideApply=true` (CRDs volumineuses).
- `helm-values.yaml` — admin local via `existingSecret`, blocs OIDC Grafana (`envValueFrom` +
  `auth.generic_oauth`) **commentés**, PVCs (Prometheus / Alertmanager / Grafana),
  rétention Prometheus, datasource Loki (`additionalDataSources`), dossier Grafana des dashboards maison, relabeling
  `instance` du node-exporter, scrapes control-plane désactivés
- `manifests/namespace.yaml` — ns `monitoring`
- `manifests/grafana-httproute.yaml` — HTTPRoute Grafana → `shared-gw`
- `manifests/grafana-admin.sealed.yaml` — `SealedSecret` `grafana-admin`, clés `admin-user` /
  `admin-password` : le **seul** identifiant d'accès à Grafana
- `manifests/grafana-oidc.externalsecret.yaml` — `ExternalSecret` `grafana-oidc`, clé `client-secret`,
  servi par [openbao](../../infra/openbao/README.md). **Non référencé dans `kustomization.yaml`**
  tant que le SSO est commenté (cf. § SSO)
- `manifests/grafana-admin.externalsecret.yaml` — ancien canal openbao du compte admin,
  **non référencé** : remplacé par le `SealedSecret` ci-dessus, les deux visent le même `Secret`
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
- `manifests/dashboard-alertes.yaml` — dashboard « Alertes — cluster » : tuiles critiques /
  warnings / pending / chaîne d'alerting, tableau des alertes **firing et pending** avec leur
  ancienneté, historique par alerte, courbe par sévérité. Variables Composant (openbao / velero /
  openebs / chart) et Sévérité
- `manifests/alertmanager-smtp.externalsecret.yaml` — `ExternalSecret` `alertmanager-smtp`, clés
  `username` / `password` du relais SMTP. **Non référencé dans `kustomization.yaml`** tant que la
  clé n'est pas dans le coffre (cf. § Notification mail)
- `manifests/servicemonitors-argocd.yaml` — scrape des 5 composants ArgoCD
- `manifests/kustomization.yaml` — assemblage

## Contraintes

- Un fichier référencé mais absent casse `kustomize build` et met toute l'Application en erreur :
  garder la ligne **commentée** tant que le secret n'existe pas.
- **Le compte admin est le seul accès à Grafana** tant que le SSO est commenté : perdre son mot
  de passe, c'est perdre l'interface. Il vient du `SealedSecret`, donc de Git — il ne dépend plus
  de l'état d'openbao, mais il dépend de la clé privée du contrôleur
  [sealed-secrets](../../infra/sealed-secrets/README.md), seul état non reconstructible du cluster.
- Tout ServiceMonitor destiné à ce Prometheus doit porter le label
  `release: kube-prometheus-stack` (`serviceMonitorSelectorNilUsesHelmValues`) — vaut aussi pour
  [loki](../loki/README.md), [alloy](../alloy/README.md),
  [openebs-monitoring](../../infra/openebs-monitoring/README.md) et
  [openbao-monitoring](../../infra/openbao-monitoring/README.md).
- Grafana est en `deploymentStrategy: Recreate` : son PVC est RWO node-local, un rollout en
  rolling update produirait un double-mount.
- Ne pas mettre `disable_login_form: true` : le formulaire local est aujourd'hui le seul moyen
  de se connecter, et il resterait le break-glass même si le SSO était réactivé.
- Les trois morceaux du SSO (`envValueFrom`, `auth.generic_oauth`, la ligne
  `grafana-oidc.externalsecret.yaml` du `kustomization.yaml`) se décommentent **ensemble** :
  un provider OIDC sans `client_secret` fait démarrer Grafana en erreur.

## Opérations

### Compte admin Grafana

Identifiant unique de l'interface : utilisateur **`admin`**, mot de passe porté par le
`SealedSecret` `grafana-admin` (`manifests/grafana-admin.sealed.yaml`), consommé par
`grafana.admin.existingSecret` dans `helm-values.yaml`.

Le canal est **sealed-secrets** et non openbao : le mot de passe voyage dans Git sous forme
chiffrée, il ne dépend donc pas d'un coffre descellé — ce qui compte pour la seule porte d'entrée
d'un outil qu'on ouvre justement quand le reste va mal.

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

Réactivation : décommenter les trois morceaux, puis remettre le client-secret dans le coffre —
c'est l'`ExternalSecret` `grafana-oidc` qui le sert.

```bash
kubectl -n openbao exec -ti openbao-0 -- \
  bao kv put kv/homelab/grafana/oidc client-secret=<output terraform client_secret>

# ESO reprend la valeur au prochain refreshInterval (1 h) ; pour l'appliquer tout de suite :
kubectl -n monitoring annotate externalsecret grafana-oidc force-sync=$(date +%s) --overwrite
```

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

### Dashboard « Alertes — cluster »

Vue unique sur les règles de tous les composants — [openbao-monitoring](../../infra/openbao-monitoring/README.md),
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
  15 min pour la plupart, 3 h pour `OpenBaoSealedTooLong`. Limité à `firing`, le tableau restait
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
  matchers. `OpenBaoNoActiveNode` sort avec `job` et sans `namespace`, `OpenBaoSnapshotTooOld`
  avec `namespace` et `cronjob`. Un filtre par namespace masquerait la moitié des alertes du
  coffre sans rien signaler.
- **`ALERTS_FOR_STATE` n'a pas le label `alertstate`**, `ALERTS` l'a : d'où le
  `and ignoring(alertstate)` du tableau. Une jointure `on(alertname)` mélangerait deux instances
  d'une même règle ; sans `ignoring`, elle ne matche rien — tableau vide, aucune erreur.
- **`count()` sur vecteur vide ne rend pas 0, il ne rend rien** : les quatre tuiles portent
  `or vector(0)`, sans quoi « aucune alerte » s'afficherait « No data ».
- **`ALERTS` n'existe que pendant que l'alerte sonne** : une alerte résolue sort des graphes, et
  tout disparaît à 15 j (rétention). Ce dashboard n'est pas un journal d'incidents.
- **Il n'y a toujours aucune notification** : sans receiver Alertmanager, une alerte n'existe que
  si quelqu'un ouvre cette page.

### Notification mail des alertes critiques (livré, DÉSACTIVÉ)

Tout est écrit — `manifests/alertmanager-smtp.externalsecret.yaml`, le bloc `alertmanager.config`
de `helm-values.yaml` — mais **volontairement inactif** : `alertmanagerSpec.secrets` monte le
Secret `alertmanager-smtp` comme volume, et un volume dont le Secret n'existe pas laisse le pod
Alertmanager en `ContainerCreating` **indéfiniment**. Activer avant d'avoir la clé SMTP casserait
donc l'alerting pour l'installer. Les trois morceaux se décommentent ensemble, dans cet ordre :

1. **Créer la clé SMTP chez le relais** (Brevo, Mailjet, SMTP2GO — offre gratuite suffisante).
   Relever le **login SMTP** (un identifiant dédié, `9xxxxx@smtp-brevo.com` chez Brevo, pas
   l'adresse du compte) et la **clé**. Valider l'adresse d'expéditeur choisie pour `smtp_from`,
   sinon le relais accepte les mails et les jette sans rien renvoyer à Alertmanager.
2. **Écrire la paire dans le coffre**, coffre descellé :
   ```bash
   bao kv put kv/homelab/alertmanager/smtp username='9xxxxx@smtp-brevo.com' password='<clé SMTP>'
   ```
3. **Décommenter**, en une seule fois : la ligne `alertmanager-smtp.externalsecret.yaml` de
   `manifests/kustomization.yaml`, le `secrets:` d'`alertmanagerSpec` et le bloc
   `alertmanager.config` de `helm-values.yaml`. Y renseigner `smtp_auth_username` et `smtp_from`.
   Commit → ArgoCD applique.
4. **Vérifier**, dans l'ordre — chaque étape a son mode d'échec propre :
   ```bash
   kubectl -n monitoring get externalsecret alertmanager-smtp   # SecretSynced ?
   kubectl -n monitoring get secret alertmanager-smtp           # matérialisé ?
   kubectl -n monitoring get pod -l app.kubernetes.io/name=alertmanager   # Running, pas ContainerCreating
   kubectl -n monitoring logs sts/alertmanager-kube-prometheus-stack-alertmanager -c alertmanager | grep -i smtp
   ```
   Puis un vrai mail, sans attendre une panne — router temporairement `Watchdog` vers
   `email-critique` au lieu de `"null"`, commit, attendre le mail, remettre. Le deadman switch
   sonne en permanence : c'est le seul générateur d'alerte fiable dont on dispose pour un test.

Ce que ce câblage décide, et qui se relit dans les commentaires du bloc :

- **`config` REMPLACE la configuration par défaut du chart, elle ne s'y ajoute pas.** Les
  `inhibit_rules` recopiées sont celles du chart : sans elles, un composant en `critical` enverrait
  aussi ses `warning` — plusieurs mails pour une seule panne.
- **Seul `severity = critical` part en mail.** Les warnings restent dans Grafana. Un mail qu'on
  finit par filtrer ne vaut pas mieux que pas de mail.
- **`Watchdog` est explicitement routé vers `"null"`** : il sonne toujours, il produirait une
  notification toutes les 4 h à vie. Sa valeur est de disparaître, ce qu'un mail ne peut pas dire —
  seul un service externe (healthchecks.io et consorts) peut surveiller ce silence, **et rien ne le
  fait aujourd'hui** : si Prometheus lui-même tombe, aucun mail ne partira jamais.
- **`repeat_interval: 4h`** au lieu des 12 h du chart : une panne du soir ne doit pas attendre le
  matin pour son premier rappel.
- **`smtp_auth_password_file`, jamais `smtp_auth_password`** : le mot de passe vient du volume, ce
  qui garde `helm-values.yaml` publiable. Le login, lui, est en clair — Alertmanager n'a pas de
  `smtp_auth_username_file`.
- **`tplConfig: false`** dans ce chart (vérifié en 88.2.0) : les `{{ }}` du `Subject` partent tels
  quels vers Alertmanager. Si ce flag passait à `true`, Helm les interpréterait d'abord et le sujet
  arriverait vide — il faudrait les échapper.

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
