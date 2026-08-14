# velero-monitoring

## Rôle

Volet post-bootstrap de [velero](../velero/README.md) : ce qui rend les sauvegardes
**observables**. Deux collecteurs et un jeu d'alertes, séparés du composant principal pour la même
raison que [openbao-monitoring](../openbao-monitoring/README.md) — ce sont des CRs
`monitoring.coreos.com`, dont les CRDs n'existent pas au bootstrap à froid.

Le **dashboard** Grafana ne vit pas ici mais dans
[kube-prometheus-stack](../../app/kube-prometheus-stack/README.md)
(`manifests/dashboard-velero.yaml`, dossier *Wittnerlab*, titre « Sauvegardes — velero ») : le
câblage côté Grafana appartient au composant qui porte Grafana, comme pour argocd.

## Fichiers

- `velero-monitoring.app.yaml` — Application (archétype (c)), ns `velero`, wave `2`
- `manifests/servicemonitor.yaml` — scrape du Deployment `velero` : sauvegardes, restaurations,
  état du bucket
- `manifests/podmonitor.yaml` — scrape des pods `node-agent` : copie kopia des données de PV
- `manifests/prometheusrule.yaml` — huit alertes, groupe `velero.rules`

## Contraintes

- **Les métriques du node-agent ne s'appellent pas `velero_*`.** Le code les enregistre sous le
  préfixe `podVolume` (`podVolumeMetricsNamespace = "podVolume"`), casse comprise :
  `podVolume_pod_volume_operation_latency_seconds`, `podVolume_pod_volume_backup_enqueue_count`.
  Une requête ou une alerte écrite en `velero_pod_volume_…` renvoie une série vide **sans le
  dire** — le faux négatif classique sur un outil de sauvegarde.
- **Le Service scrapé n'existe que si `metrics.enabled` reste vrai côté velero.** C'est le seul
  morceau d'observabilité qui vit dans `velero/helm-values.yaml` ; le couper viderait ce
  ServiceMonitor en silence. Les deux flags `serviceMonitor`/`nodeAgentPodMonitor` du chart, eux,
  sont volontairement à `false` avec `autodetect: false` — c'est ce composant qui pose les objets.
- **Deux alertes ne reposent sur aucune métrique velero, et ce n'est pas un oubli.**
  `VeleroDown` utilise `absent(up == 1)` et `VeleroNodeAgentNotReady` interroge
  kube-state-metrics. Elles couvrent les deux pannes qu'aucun compteur d'échec ne peut voir : plus
  rien ne se déclenche, ou les sauvegardes réussissent **à vide** parce que node-agent n'est pas là.
- **`VeleroBackupTooOld` est aveugle sans `VeleroNoBackupMetric`.** Une expression
  `time() - <métrique> > seuil` ne se déclenche jamais quand la série est *absente* — or
  `velero_backup_last_successful_timestamp` disparaît à chaque redémarrage du pod velero et n'a
  jamais existé tant qu'aucune sauvegarde n'a abouti. La seconde règle couvre ce trou. Ne pas
  supprimer l'une en gardant l'autre.
- **Dépendance CROSS-TIER (infra → app), qu'aucune sync-wave n'ordonne.** Au bootstrap à froid
  l'Application reste en erreur jusqu'à l'arrivée de kube-prometheus-stack, puis se répare seule
  (`selfHeal`). Aucun geste manuel, personne n'attend derrière.
- **Le label `release: kube-prometheus-stack` est obligatoire** sur les trois objets : c'est le
  sélecteur du prometheus-operator (`serviceMonitorSelectorNilUsesHelmValues`). Sans lui, l'objet
  est ignoré sans erreur.
- **Les compteurs `velero_repo_maintenance_*` n'existent pas tant qu'aucune maintenance n'a
  tourné.** Un `CounterVec` Prometheus n'exporte une série qu'après son premier incrément :
  vérifié sur l'endpoint réel, ces métriques sont absentes sur une installation neuve. Conséquence
  assumée — `VeleroRepoMaintenanceFailing` ne peut pas se déclencher avant la première maintenance,
  et le panneau correspondant du dashboard reste vide jusque-là. Ce n'est pas un faux négatif
  dangereux (aucune maintenance n'a échoué s'il n'y en a pas eu), mais un panneau vide ne vaut pas
  preuve de bonne santé.
- **Aucune alerte ne surveille la taille du bucket.** velero n'expose que la taille du tarball
  d'objets, jamais le volume du dépôt kopia. La seule mesure fiable est côté GCP
  (`gcloud storage du`), hors cluster, donc hors Prometheus.

## Opérations

- **Vérifier que les cibles sont scrapées** :
  ```bash
  kubectl -n velero get servicemonitor,podmonitor,prometheusrule
  kubectl -n monitoring exec -ti sts/prometheus-kube-prometheus-stack-prometheus -c prometheus -- \
    wget -qO- 'http://localhost:9090/api/v1/targets?state=active' | grep -o 'velero[^"]*' | sort -u
  ```
- **Vérifier qu'une métrique existe vraiment avant d'écrire une règle dessus** — la seule façon de
  ne pas produire une alerte silencieuse :
  ```bash
  kubectl -n velero port-forward deploy/velero 8085:8085 &
  curl -s localhost:8085/metrics | grep '^velero_backup' | cut -d'{' -f1 | sort -u
  kubectl -n velero port-forward ds/node-agent 8086:8085 &
  curl -s localhost:8086/metrics | grep '^podVolume' | cut -d'{' -f1 | sort -u
  ```
- **Lister les alertes actives du groupe** :
  ```bash
  kubectl -n monitoring exec -ti sts/prometheus-kube-prometheus-stack-prometheus -c prometheus -- \
    wget -qO- 'http://localhost:9090/api/v1/rules?type=alert' | grep -o 'Velero[A-Za-z]*'
  ```
- **Ouvrir le dashboard** : Grafana → dossier *Wittnerlab* → « Sauvegardes — velero »
  (uid `velero-backups`). Il vit dans
  [kube-prometheus-stack](../../app/kube-prometheus-stack/README.md), pas ici — et jamais édité
  depuis l'UI : le ConfigMap versionné est la source.
