# Supervision (kube-prometheus-stack)

| | malygos | kalecgos |
|---|---|---|
| Prometheus | complet : stocke tout (15 j, 50 Gi), reçoit l'écriture distante | agent : collecte et envoie à malygos |
| Grafana, Alertmanager | ✓ | |
| node-exporter, kube-state-metrics, opérateur | ✓ | ✓ |
| Label `cluster` (scrapeClass par défaut) | `bleu-malygos` | `bleu-kalecgos` |

| Fichier | Rôle |
|---|---|
| `clusters/<nom>/prometheus-operator-crds/` | CRDs de l'opérateur (`ServiceMonitor`, `PodMonitor`…), posées au [bootstrap](bootstrap/01-crds.md) |
| `components/kube-prometheus-stack/values.yaml` | CRDs non installées par le chart, control plane Talos et kube-proxy désactivés, sélecteurs ouverts, webhook certifié par cert-manager, `instance` node-exporter = nom du nœud |
| `components/kube-prometheus-stack/manifests/namespace.yaml` | `monitoring`, PSA `privileged` (node-exporter) |
| `clusters/bleu-malygos/kube-prometheus-stack/values.yaml` | stockage, rétention, réception, routes, Grafana sans état |
| `clusters/bleu-kalecgos/kube-prometheus-stack/values.yaml` | agent (`PrometheusAgent`), envoi vers `prometheus.lan.wittner.tech` ; sans Grafana, Alertmanager ni règles |
| `clusters/bleu-malygos/kube-prometheus-stack/manifests/alertmanager-config.yaml` | `ExternalSecret` : config Alertmanager entière, destinataire depuis `secret/alertmanager` (`email`) |
| `clusters/bleu-malygos/kube-prometheus-stack/manifests/grafana-admin.yaml` | `ExternalSecret` : mot de passe admin depuis `secret/grafana` (`admin_password`) |
| `clusters/bleu-malygos/kube-prometheus-stack/manifests/dashboard-*.yaml` | dashboards custom, dossier `Wittnerlab` |
| `clusters/<nom>/kube-prometheus-stack/kube-prometheus-stack.app.yaml` | `kube-prometheus-stack-<cluster-court>` |

| URL | |
|---|---|
| `https://grafana.lan.wittner.tech` | Authelia (groupe `admins` → Admin, sinon Viewer) ; utilisateur `admin` en secours |
| `https://prometheus.lan.wittner.tech` | UI, API ; écriture distante sur `/api/v1/write`, **sans authentification** (LAN) |
| `https://alertmanager.lan.wittner.tech` | alertes par mail ([relais SMTP](smtp.md)), sauf `Watchdog` |

## Destinataire des alertes (une fois)

Hors dépôt (public) : dans OpenBao.

```sh
read -r "EMAIL?Destinataire des alertes : "
bao kv put secret/alertmanager email="$EMAIL"
unset EMAIL
```

Changer : même commande. ESO relit toutes les heures ; Alertmanager recharge seul (pas de redémarrage).

Tester : une alerte factice, envoyée après `group_wait` (30 s).

```sh
curl -s -XPOST https://alertmanager.lan.wittner.tech/api/v2/alerts -H 'Content-Type: application/json' \
  -d '[{"labels":{"alertname":"TestMail","severity":"warning","namespace":"test"},"annotations":{"summary":"test du mail"}}]'
```

## Mot de passe Grafana (une fois)

CLI locale connectée à OpenBao ([openbao](openbao.md)) :

```sh
read -rs "PW?Mot de passe Grafana : "; echo
printf %s "$PW" | bao kv put secret/grafana admin_password=-   # patch si secret/grafana a déjà d'autres champs
unset PW
```

Changer : même commande ; ESO relit toutes les heures, puis redémarrer Grafana (`kubectl --context admin@bleu-malygos -n monitoring rollout restart deploy/kube-prometheus-stack-grafana`).

## Moniteurs des composants

Chaque composant déclare le sien ; Prometheus les prend tous (sélecteurs ouverts).

| Composant | Moniteur | Où |
|---|---|---|
| ArgoCD (malygos) | 5 `ServiceMonitor` (controller, server, repo-server, notifications, applicationset) | `clusters/bleu-malygos/argocd/manifests/servicemonitors.yaml` |
| OpenEBS LVM | `ServiceMonitor` `openebs-lvm-node`, `instance` = nom du nœud | `components/openebs/manifests/servicemonitor.yaml` |
| Velero | `ServiceMonitor` serveur (schedule vide réécrit en `manuel`) + `PodMonitor` node-agent | option `metrics` du chart, `components/velero/values.yaml` |
| Relais SMTP | `ServiceMonitor` `smtp-relay-metrics` (postfix-exporter : file d'attente, envois, rejets) | option `metrics` du chart, `components/smtp-relay/values.yaml` |
| Objets velero (Backup, PodVolumeBackup) | kube-state-metrics `customResourceState` : `velero_backup_object_*`, `velero_pvb_object_*` | `components/kube-prometheus-stack/values.yaml` |

## Dashboards custom

ConfigMap dans `clusters/bleu-malygos/kube-prometheus-stack/manifests/`, ajoutée à la `kustomization.yaml` :

| Champ | Valeur |
|---|---|
| label | `grafana_dashboard: "1"` (chargé par le sidecar) |
| annotation | `grafana_folder: Wittnerlab` (dossier dans l'UI) |
| variables | `cluster` puis `instance`/`node`/`namespace` filtrés par `$cluster` ; choix unique quand les namespaces des deux clusters s'additionneraient |
| mise en page | un graphique par ligne (`w: 24`), légende en liste à droite ; `stat` et `bargauge` groupés |

| Dashboard | Contenu |
|---|---|
| `Machines` (`dashboard-machines.yaml`) | tous les nœuds node-exporter : CPU, RAM, PSI, disques, réseau, températures ; rangées « Diagnostic » repliées |
| `Storage — cluster` (`dashboard-stockage.yaml`) | état des nœuds (tableau) et VG LVM d'OpenEBS : capacité, place libre, métadonnées |
| `Backups — velero` (`dashboard-velero.yaml`) | fraîcheur des sauvegardes, bucket, inventaire par schedule et par objet Backup, données kopia, restaurations |
| `GitOps — ArgoCD` (`dashboard-argocd.yaml`) | Applications (sync/santé), synchros, contrôleur, repo-server Git, composants |
| `Resources — cluster / namespaces / workloads / pods` (`dashboard-ressources-*.yaml`) | CPU et mémoire : utilisation, requests, limits, allouable ; un cluster à la fois |
| `Resources — volumes` (`dashboard-ressources-volumes.yaml`) | PVC : remplissage, inodes, saturation, cycle de vie ; VG LVM. Un cluster à la fois |
| `Alerts — cluster` (`dashboard-alertes.yaml`) | alertes actives et historique, par famille (Kubernetes, nœuds, supervision) |

Modifier : éditer le JSON dans Git (une modification dans l'UI est perdue au redémarrage) ; export depuis l'UI possible puis recopie dans la ConfigMap.

## Limites

- Grafana sans état : un tableau de bord modifié dans l'UI est perdu au redémarrage. Le garder : export JSON → ConfigMap labellisée `grafana_dashboard: "1"` dans Git.
- Pas de métriques scheduler, controller-manager, etcd : Talos les sert sur `127.0.0.1`. Les ouvrir dans `homelab_talos` puis réactiver `kubeScheduler`, `kubeControllerManager`, `kubeEtcd`.
- Agrandir Prometheus : `storage` dans `values.yaml` + `retentionSize` (≈ 90 % du volume) ; voir [stockage](stockage.md) pour le StatefulSet.

## Vérifier

```sh
kubectl --context admin@bleu-malygos -n monitoring get pods,pvc
kubectl --context admin@bleu-malygos -n monitoring get externalsecret      # SecretSynced
curl -s https://prometheus.lan.wittner.tech/api/v1/targets?state=unhealthy | jq '.data.activeTargets | length'   # 0
curl -s 'https://prometheus.lan.wittner.tech/api/v1/query?query=count(up)by(cluster)' | jq -c '.data.result[] | [.metric.cluster, .value[1]]'   # les deux clusters
kubectl --context admin@bleu-kalecgos -n monitoring logs prom-agent-kube-prometheus-stack-prometheus-0 -c prometheus | grep -i remote   # erreurs d'envoi
```
