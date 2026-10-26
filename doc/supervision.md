# Supervision (kube-prometheus-stack)

| | malygos | kalecgos |
|---|---|---|
| Prometheus | complet : stocke tout (15 j, 50 Gi), reçoit l'écriture distante | agent : collecte et envoie à malygos |
| Grafana, Alertmanager | ✓ | |
| node-exporter, kube-state-metrics, opérateur | ✓ | ✓ |
| Label `cluster` (scrapeClass par défaut) | `bleu-malygos` | `bleu-kalecgos` |

| Fichier | Rôle |
|---|---|
| `components/kube-prometheus-stack/values.yaml` | control plane Talos et kube-proxy désactivés, sélecteurs ouverts, webhook certifié par cert-manager |
| `components/kube-prometheus-stack/manifests/namespace.yaml` | `monitoring`, PSA `privileged` (node-exporter) |
| `clusters/bleu-malygos/kube-prometheus-stack/values.yaml` | stockage, rétention, réception, routes, Grafana sans état |
| `clusters/bleu-malygos/kube-prometheus-stack/manifests/grafana-admin.yaml` | `ExternalSecret` : mot de passe admin depuis `secret/grafana` (`admin_password`) |
| `clusters/<nom>/kube-prometheus-stack/kube-prometheus-stack.app.yaml` | `kube-prometheus-stack-<cluster-court>` |

| URL | |
|---|---|
| `https://grafana.lan.wittner.tech` | utilisateur `admin` |
| `https://prometheus.lan.wittner.tech` | UI, API ; écriture distante sur `/api/v1/write`, **sans authentification** (LAN) |
| `https://alertmanager.lan.wittner.tech` | aucun destinataire configuré |

## Mot de passe Grafana (une fois)

CLI locale connectée à OpenBao ([openbao](openbao.md)) :

```sh
read -rs "PW?Mot de passe Grafana : "; echo
printf %s "$PW" | bao kv put secret/grafana admin_password=-   # patch si secret/grafana a déjà d'autres champs
unset PW
```

Changer : même commande ; ESO relit toutes les heures, puis redémarrer Grafana (`kubectl --context admin@bleu-malygos -n monitoring rollout restart deploy/kube-prometheus-stack-grafana`).

## Limites

- Grafana sans état : un tableau de bord modifié dans l'UI est perdu au redémarrage. Le garder : export JSON → ConfigMap labellisée `grafana_dashboard: "1"` dans Git.
- Pas de métriques scheduler, controller-manager, etcd : Talos les sert sur `127.0.0.1`. Les ouvrir dans `homelab_talos` puis réactiver `kubeScheduler`, `kubeControllerManager`, `kubeEtcd`.
- Agrandir Prometheus : `storage` dans `values.yaml` + `retentionSize` (≈ 90 % du volume) ; voir [stockage](stockage.md) pour le StatefulSet.

## Vérifier

```sh
kubectl --context admin@bleu-malygos -n monitoring get pods,pvc
kubectl --context admin@bleu-malygos -n monitoring get externalsecret      # SecretSynced
curl -s https://prometheus.lan.wittner.tech/api/v1/targets?state=unhealthy | jq '.data.activeTargets | length'   # 0
curl -s 'https://prometheus.lan.wittner.tech/api/v1/query?query=count(up)by(cluster)' | jq -c '.data.result[] | [.metric.cluster, .value[1]]'
```
