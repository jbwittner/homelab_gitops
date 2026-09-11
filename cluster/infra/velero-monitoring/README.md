# velero-monitoring


> [!CAUTION]
> **RETIRÉ DU DÉPLOIEMENT LE 11 SEPTEMBRE 2026.** Le fichier `velero-monitoring.noapp.yaml` porte l'extension
> `.noapp.yaml` : il ne matche plus le glob du tier-2, l'`Application` a donc été *prunée* et son
> finalizer `resources-finalizer.argocd.argoproj.io` a emporté les ressources gérées.
>
> **Pourquoi :** il n'a plus de sujet : `velero` est passé en `.noapp.yaml` le même jour. **Le laisser actif aurait fait sonner `VeleroDown` en permanence** — son expression est `absent(up{job="velero"} == 1)`, qui se déclenche précisément quand la cible disparaît. Une alerte qui sonne toujours n'est plus lue, et c'est celle-là qu'on ne veut surtout pas apprendre à ignorer.
>
> **Ce qui restait au moment du retrait**, vérifié : six règles, dont deux déjà `firing` (`VeleroBackupStorageLocationUnavailable`, `VeleroRepoMaintenanceFailing`) et deux commentées depuis la bascule de la forge.
>
> **Pour le remettre :** renommer en `.app.yaml`. ⚠️ Dans le MÊME commit que `velero` : l'un sans l'autre est soit un service non surveillé, soit une alerte perpétuelle.

## Rôle

Volet post-bootstrap de [velero](../velero/README.md) : ce qui rend les sauvegardes
**observables**. Deux collecteurs et un jeu d'alertes, séparés du composant principal pour la même
raison que les autres `*-monitoring` du dépôt — ce sont des CRs `monitoring.coreos.com`, dont les
CRDs n'existent pas au bootstrap à froid.

Le **dashboard** Grafana ne vit pas ici mais dans
[kube-prometheus-stack](../../app/kube-prometheus-stack/README.md)
(`manifests/dashboard-velero.yaml`, dossier *Wittnerlab*, titre « Sauvegardes — velero ») : le
câblage côté Grafana appartient au composant qui porte Grafana, comme pour argocd.

## Fichiers

- `velero-monitoring.app.yaml` — Application (archétype (c)), ns `velero`, wave `2`
- `manifests/servicemonitor.yaml` — scrape du Deployment `velero` : sauvegardes, restaurations,
  état du bucket
- `manifests/podmonitor.yaml` — scrape des pods `node-agent` : copie kopia des données de PV
- `manifests/prometheusrule.yaml` — huit alertes, groupe `velero.rules`. ⚠️ **Deux d'entre elles
  — `VeleroBackupTooOld` et `VeleroNoBackupMetric` — sont COMMENTÉES depuis le 2026-09-11** : il
  n'y a plus de schedule (voir *Contraintes*)

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
- **Plus aucune sauvegarde n'est planifiée dans ce cluster depuis le 2026-09-11.** La forge était
  le seul namespace de `includedNamespaces` ; elle a quitté le cluster
  ([archive/forgejo](../../../archive/forgejo/README.md)) et `schedules.daily` est passée à
  `disabled: true` dans [velero](../velero/README.md). Le composant reste debout — contrôleur,
  node-agent, BackupStorageLocation, dépôt kopia — et les backups existants restent restaurables
  jusqu'à expiration de leur TTL. ⚠️ Les **deux règles de fraîcheur** sont commentées en
  conséquence : elles sonneraient sans fin, et une alerte qui sonne toujours n'est plus lue. Elles
  se remettent **dans le même commit** que la réactivation de la schedule, **ensemble** — et tant
  qu'elles sont commentées, rien ne surveille la fraîcheur des sauvegardes, ce qui est exact : il
  n'y en a aucune.
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
- **Prometheus supprime les labels vides — c'est ce qui fait disparaître les backups manuels.**
  velero étiquette ses métriques par `schedule` et y met une chaîne vide pour une sauvegarde
  lancée à la main. Le label n'est donc pas stocké, et la cascade est entièrement silencieuse :
  `label_values(velero_backup_last_status, schedule)` ne propose que `velero-daily`, le « All »
  d'un dashboard s'interpole en `schedule=~"(velero-daily)"`, et les sauvegardes manuelles
  s'évaporent des graphes alors que leurs métriques existent. La parade est un `metricRelabelings`
  du ServiceMonitor qui réécrit le label vide en **`manuel`** au scrape. Conséquences à connaître :
  toute requête doit viser `schedule="manuel"` et non `schedule=""`, et les échantillons **déjà
  stockés** gardent l'ancienne forme jusqu'à expiration de la rétention (le dashboard couvre cette
  période avec un `label_replace`, retirable ensuite).
- **Le corollaire du point précédent : `manuel` doit être exclu des règles d'ancienneté.** Une
  sauvegarde manuelle est one-shot — sa série ne sera plus jamais rafraîchie, donc elle franchit
  fatalement n'importe quel seuil de fraîcheur et n'en redescend plus. `VeleroBackupTooOld` filtre
  pour cette raison `schedule!="manuel"` en plus de `schedule!=""` (l'ancienne forme, encore
  présente dans les échantillons antérieurs au relabeling). Le garde-fou d'origine ne portait que
  sur la chaîne vide : le relabeling l'a rendu inopérant, et un backup manuel allumait une alerte
  critique 36 h plus tard, définitivement. Les règles `increase(...)` sur les échecs, elles,
  gardent `manuel` volontairement : un backup manuel qui échoue est un vrai échec.
- **Troisième conséquence du relabeling, corrigée le 2026-09-09 : `velero_backup_.*` est plus
  large que « les sauvegardes ».** Le regex attrape aussi `velero_backup_**location**_status_gauge`,
  qui décrit une **destination** et n'a aucun rapport avec une schedule. Les séries de
  `BackupStorageLocation` sortaient donc estampillées `schedule="manuel"` alors qu'aucune schedule
  de ce nom n'existe — et le label ressortait tel quel **dans le mail** de
  `VeleroBackupStorageLocationUnavailable`, où il ressemble à un indice et envoie chercher une
  schedule fantôme en pleine panne. Aucune alerte n'était faussée : c'est un défaut de lisibilité,
  et il n'apparaît qu'en lisant un vrai mail — jamais en relisant la configuration.
  Un second `metricRelabelings` retire le label sur ces séries. ⚠️ Il n'est pas indépendant du
  premier, c'est son **rattrapage** : les deux se déplacent ensemble. Et c'est un rattrapage plutôt
  qu'un regex plus étroit parce que RE2 n'a pas de lookahead négatif — `velero_backup_(?!location)`
  n'est pas exprimable.
- **La liste des sauvegardes ne peut PAS venir des métriques de velero.** Elles sont agrégées par
  schedule et écrasées à chaque exécution : `velero_backup_tarball_size_bytes` ne décrit que la
  dernière, jamais l'historique. L'inventaire « une ligne par sauvegarde » vient de
  **kube-state-metrics** en mode `customResourceState`, configuré dans le helm-values de
  [kube-prometheus-stack](../../app/kube-prometheus-stack/README.md) : `velero_backup_object_*`
  (objets `Backup`) et `velero_pvb_object_bytes` (octets par `PodVolumeBackup`). Sans la règle RBAC
  `velero.io` qui l'accompagne, KSM ne voit pas ces CRs et les séries restent vides **sans erreur
  dans ses logs**.
- **`sum(velero_pvb_object_bytes)` n'est pas la taille du bucket.** C'est le volume *copié* par
  kopia avant déduplication, et il ignore le tarball d'objets. L'occupation réelle se mesure
  côté GCP (`gcloud storage du`), jamais depuis Prometheus.
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
- **Un `BackupStorageLocation` supprimé laisse sa métrique derrière lui, et l'alerte ne s'éteint
  jamais seule.** velero pose `velero_backup_location_status_gauge` quand il découvre un BSL, mais
  il ne la RETIRE PAS quand le BSL disparaît : la série continue d'être exportée à `0`, donc
  `VeleroBackupStorageLocationUnavailable` reste en `firing` indéfiniment sur une destination qui
  n'existe plus. Ce n'est pas un défaut de la règle — l'expression est correcte, c'est la métrique
  qui ment. Constaté le 2026-09-09 : un BSL `drill-broken` créé à la main pour éprouver la règle,
  puis supprimé, a laissé une alerte critique allumée alors que `kubectl get backupstoragelocation`
  ne montrait plus que `default` en `Available` et que la sauvegarde de 03:00 était `Completed`.
  ⚠️ **Tout exercice qui crée un BSL doit donc se terminer par un redémarrage du Deployment velero**
  (voir *Opérations*), sinon le nettoyage est incomplet et l'alerte survit à l'exercice.
  Ne PAS « corriger » en épinglant l'expression sur `backup_location_name="default"` : ça éteindrait
  aussi la surveillance de tout BSL ajouté plus tard, en silence — on troquerait un faux positif
  bruyant contre un faux négatif muet, sur la seule alerte qui nomme la cause d'un bucket injoignable.

## Opérations

- **Vérifier que les cibles sont scrapées** :
  ```bash
  kubectl -n velero get servicemonitor,podmonitor,prometheusrule
  kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 19090:9090 &
  curl -s 'localhost:19090/api/v1/targets?state=active' | grep -o 'velero[^"]*' | sort -u
  ```
  ⚠️ Pas de `kubectl exec` dans le conteneur `prometheus` : son image n'a **ni shell ni `wget`**
  (`exec: "sh": executable file not found in $PATH`). Le seul accès à l'API passe par un
  port-forward.
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
  kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 19090:9090 &
  curl -s 'localhost:19090/api/v1/rules?type=alert' | grep -o 'Velero[A-Za-z]*' | sort -u
  ```
- **Éteindre une alerte de BSL restée allumée après un exercice** — le gauge d'un BSL supprimé n'est
  purgé que par un redémarrage du serveur (voir *Contraintes*) :
  ```bash
  kubectl -n velero get backupstoragelocation            # confirmer d'abord que le BSL a bien disparu
  kubectl -n velero rollout restart deployment/velero    # aucune sauvegarde en cours : vérifier avant
  ```
  Le `restartedAt` posé par `rollout restart` **ne crée pas de dérive ArgoCD** : avec
  `ServerSideApply=true`, l'annotation appartient au field manager `kubectl-rollout` et non à
  ArgoCD, qui ne la voit donc pas dans son diff — l'Application reste `Synced`. Ça reste un geste
  impératif, à ne faire que pour cette panne-là.
- **Ouvrir le dashboard** : Grafana → dossier *Wittnerlab* → « Sauvegardes — velero »
  (uid `velero-backups`). Il vit dans
  [kube-prometheus-stack](../../app/kube-prometheus-stack/README.md), pas ici — et jamais édité
  depuis l'UI : le ConfigMap versionné est la source.
