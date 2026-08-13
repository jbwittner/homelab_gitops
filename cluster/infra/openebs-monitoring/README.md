# openebs-monitoring

## Rôle

Volet **post-bootstrap** d'[openebs](../openebs/README.md) : le scrape des métriques du driver
LocalPV-LVM et les alertes qui vont avec. Rien ici n'est nécessaire pour que le cluster ait du
stockage — c'est précisément la raison de la séparation.

Le composant `openebs` doit être debout au tout début du bootstrap (la StorageClass par défaut
conditionne tous les PVC, à commencer par celui d'[openbao](../openbao/README.md)), alors que ces
deux objets sont des CRs `monitoring.coreos.com` : ils n'existent qu'une fois
[kube-prometheus-stack](../../app/kube-prometheus-stack/README.md) installé. Les garder dans
`openebs` mettait cette Application en échec sur un cluster nu, et bloquait derrière elle toutes
les waves suivantes. Même raisonnement que les ServiceMonitors ArgoCD, hébergés côté
kube-prometheus-stack.

## Fichiers

- `openebs-monitoring.app.yaml` — Application (archétype (c), path → `manifests/`), **wave 2**,
  ns `openebs`
- `manifests/servicemonitor.yaml` — scrape de l'exporter du node-plugin (port `metrics`, 30 s) +
  relabeling `__meta_kubernetes_pod_node_name` → label `node`
- `manifests/prometheusrule.yaml` — alertes `openebs-lvm.rules` : remplissage du VG (85 / 95 %),
  PV manquant, métadonnées LVM saturées, LV dégradé, exporter muet
- `manifests/kustomization.yaml` — assemblage

## Contraintes

- **Le label `release: kube-prometheus-stack` est obligatoire** sur les deux objets
  (`serviceMonitorSelectorNilUsesHelmValues` / `ruleSelector` du chart) : sans lui, Prometheus les
  ignore silencieusement — pas d'erreur, juste des graphes et des alertes qui n'existent pas.
- **Le label `node` est load-bearing pour les alertes.** Le stockage est node-local : il y a un VG
  `lvmvg` par nœud, tous exposés sous le même `name="lvmvg"`. L'exporter étant un DaemonSet, son
  `instance` natif est l'IP du pod, réattribuée à chaque redémarrage. C'est le relabeling du
  ServiceMonitor qui attache `node`, et chaque annotation d'alerte s'en sert pour nommer le nœud
  concerné. Retirer le relabeling rend deux VG saturés indiscernables dans une notification.
- **Les seuils sont évalués série par série, jamais agrégés** : 20 Gio libres répartis 19 + 1 ne
  permettent pas de provisionner 5 Gio. Ne pas « simplifier » les expressions par un `sum()`.
- **Le namespace `openebs` n'appartient pas à ce composant** : il est créé et labellisé PSA
  `privileged` par `openebs/manifests/namespace.yaml` (wave -1). Pas de `CreateNamespace` ici, et
  ne rien ajouter qui présuppose de posséder ce namespace.
- **La dépendance à kube-prometheus-stack n'est pas ordonnançable** : ce composant est dans
  `cluster/infra`, le stack dans `cluster/app`, et les deux app-of-apps se synchronisent
  indépendamment. La wave 2 ne fait que garantir un point : ne bloquer personne dans `infra`.
- **Ne pas remonter la wave.** En wave 0, une sync en échec (CRDs absentes) retiendrait `openebs`
  et `openbao` ; en wave 2, ce composant est derrière tout le monde et n'a rien à retenir.

## Opérations

- **Bootstrap à froid** : cette Application reste en erreur (`ServiceMonitor` /`PrometheusRule`
  introuvables côté API) tant que kube-prometheus-stack n'est pas déployé — attendu, sans
  conséquence sur le stockage. Elle se répare seule au retry suivant, `selfHeal` étant actif.
  Aucun geste manuel.
- **Debug** :
  ```bash
  kubectl -n openebs get servicemonitor,prometheusrule --show-labels   # release=kube-prometheus-stack
  kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
  # Status → Targets, ou directement :
  curl -s 'localhost:9090/api/v1/query?query=up{job="openebs-lvm-localpv-node-service"}'
  curl -s 'localhost:9090/api/v1/query?query=lvm_vg_free_size_bytes'   # une série PAR NŒUD
  ```
- **Métriques absentes alors que le driver tourne** : vérifier d'abord le label `release`, puis
  que le Service du node-plugin porte bien `openebs.io/component-name: openebs-lvm-node` (le
  sélecteur du ServiceMonitor) — un renommage upstream lors d'un bump du chart casserait le
  scrape sans rien signaler.
- **Lecture des métriques** : dashboard « Ressources — volumes »
  ([kube-prometheus-stack](../../app/kube-prometheus-stack/README.md)) — remplissage par PVC et
  état du VG.
