# cnpg-monitoring

## Rôle

Volet **observabilité de la sauvegarde** des bases [cnpg](../cnpg/README.md) : un PodMonitor sur le
collecteur des instances PostgreSQL, et sept alertes sur l'état de la chaîne barman-cloud
([cnpg-barman-plugin](../cnpg-barman-plugin/README.md)).

> [!CAUTION]
> **Ce composant n'est pas un confort, il tient une décision.** Les PVC des bases CNPG ont été
> **retirés du périmètre de copie kopia** de velero
> ([`volume-policies.yaml`](../../infra/velero/manifests/volume-policies.yaml), règle `pvcLabels`)
> au profit de la sauvegarde native. Cet arbitrage n'est défendable **que** parce qu'une détection
> passive d'une chaîne native morte en silence a été posée en face — c'est-à-dire ces alertes.
> Supprimer ces alertes ne dégrade pas l'observabilité : cela rend l'exclusion indéfendable. Les
> deux décisions se tiennent ensemble.

## Fichiers

- `cnpg-monitoring.app.yaml` — Application (archétype (c)), ns `cnpg-system`, wave `2`
- `manifests/podmonitor.yaml` — scrape du port `metrics` (9187) des pods d'instance, **tous
  namespaces**
- `manifests/prometheusrule.yaml` — sept alertes, groupe `cnpg.backup.rules`

## Contraintes

- **Le PodMonitor est écrit à la main, pas activé par `spec.monitoring.enablePodMonitor`.**
  L'opérateur en poserait bien un, mais **sans** le label `release: kube-prometheus-stack` qu'exige
  le sélecteur de Prometheus (défaut du chart, `podMonitorSelectorNilUsesHelmValues: true`) : il
  existerait, paraîtrait sain, et ne serait jamais scrapé. Même motif que
  [velero-monitoring](../../infra/velero-monitoring/README.md). Les métriques, elles, sont servies
  **sans condition** par le collecteur — il n'y a rien à activer côté `Cluster`.
- **`namespaceSelector: {any: true}`, et non une liste.** Les pods scrapés vivent dans les
  namespaces des applications consommatrices (`bankwiz-dev` aujourd'hui), jamais dans
  `cnpg-system`. Une liste explicite serait à maintenir à chaque base ajoutée, et son oubli
  produirait une base non surveillée, silencieusement.
- **`podTargetLabels: [cnpg.io/cluster]` est load-bearing.** C'est ce qui donne le label de série
  `cnpg_io_cluster`, sur lequel s'appuient l'annotation de chaque alerte **et** la liste blanche de
  `CNPGBackupChainAbsent`. Le retirer ne casse pas les règles : il les rend illisibles et vide la
  liste blanche de son sens.

### Trois pièges de métriques

> [!IMPORTANT]
> **Depuis le 2026-10-16, une base non sauvegardée : `bankwiz-db`** (ns `bankwiz-dev`).
> `CNPGMetricsAbsent` est réactivée avec elle ; `CNPGBackupChainAbsent` et les trois règles barman
> restent commentées tant qu'aucune base n'est sous sauvegarde. Si `bankwiz-db` disparaît sans
> remplaçante, recommenter `CNPGMetricsAbsent` dans le même commit.
>
> **Aucune base dans ce cluster du 2026-09-11 au 2026-10-16** (la seule a quitté le cluster avec
> son application). Les règles fondées sur une
> VALEUR n'ont plus de série à évaluer et sont muettes, ce qui est correct. Les **deux règles en
> `absent(...)`** — `CNPGBackupChainAbsent` et `CNPGMetricsAbsent` — sonneraient en permanence :
> elles sont **commentées** dans `manifests/prometheusrule.yaml`, et se remettent dans le même
> commit que le premier `Cluster` recréé ici. Les relevés ci-dessous, faits sur cette ancienne
> base, restent valables — ce sont des propriétés de CNPG, pas d'une base.

Tous les trois relevés sur une instance réelle en CNPG 1.30.0. Chacun produit, si on l'ignore, soit une
alerte qui hurle en permanence, soit une alerte muette.

1. **`cnpg_pg_stat_archiver_seconds_since_last_archival` n'est PAS un indicateur de fraîcheur.**
   C'est le choix intuitif, et il est faux : PostgreSQL ne force un changement de segment sur
   `archive_timeout` (300 s ici) que s'il y a **eu** de l'activité WAL depuis le dernier. Une base
   au repos n'archive donc rien, indéfiniment — la valeur relevée sur une instance **saine** était
   de **144 221 s, soit 40 heures**. Le bon signal d'une chaîne cassée est le **backlog**
   (`cnpg_collector_pg_wal_archive_status{value="ready"}`), nul au repos et croissant dès que
   l'archivage échoue.
2. **`cnpg_collector_last_available_backup_timestamp` vaut `0`, pas « absent »**, quand aucune
   sauvegarde n'existe. Une règle `time() - métrique > seuil` sans garde `> 0` se déclenche donc
   **pour l'éternité** sur toute base non sauvegardée. C'est aussi pourquoi la forme `absent(...)`
   de `VeleroNoBackupMetric` ne se transpose pas telle quelle : la série existe, elle est à zéro —
   d'où `CNPGNoBackupYet`, qui teste `== 0`.
3. **Les `cnpg_collector_*_backup_timestamp` sont marquées `(Deprecated)`** par l'amont depuis le
   passage aux plugins CNPG-I. Leur remplacement est servi par le **sidecar**, sur le même endpoint
   9187, sous le préfixe du plugin : `barman_cloud_cloudnative_pg_io_last_available_backup_timestamp`
   et ses deux voisines. Ce sont elles qui sont utilisées ici.

   ⚠️ **Conséquence structurelle** : ces métriques n'existent **que** pour les bases dont le
   `spec.plugins` est câblé. C'est ce qui dispense `CNPGNoBackupYet` d'une liste blanche —
   l'intention « cette base doit être sauvegardée » est portée par le `Cluster` lui-même. Le revers
   est qu'une base à qui on **retire** `spec.plugins` devient silencieuse, d'où
   `CNPGBackupChainAbsent`, seule règle du fichier à nommer explicitement les bases attendues.

## Alertes

| Alerte | Sévérité | Ce qu'elle attrape |
| --- | --- | --- |
| `CNPGWalArchivingBacklog` | critical | Segments WAL en attente depuis > 30 min : credentials invalides, bucket disparu, Secret absent. **Aussi une alerte de disponibilité** — un `pg_wal` qui ne se vide plus finit par remplir le PVC et arrêter PostgreSQL |
| `CNPGWalArchivingFailing` | warning | Échecs d'archivage qui se **résorbent** — invisible du backlog, mais déjà une dégradation |
| `CNPGBackupTooOld` | critical | Aucune sauvegarde de base réussie depuis 36 h (schedule quotidienne à 02:00). Seuil aligné sur `VeleroBackupTooOld` |
| `CNPGLastBackupFailed` | warning | La tentative la plus récente a échoué : se déclenche dès la première nuit ratée |
| `CNPGNoBackupYet` | warning | Le plugin est câblé sur une base mais aucune sauvegarde n'a jamais réussi. Comble l'angle mort de la garde `> 0` de `CNPGBackupTooOld` |
| ~~`CNPGBackupChainAbsent`~~ | critical | ⚠️ **commentée** (plus aucune base) — les métriques du plugin ont disparu pour une base attendue : `spec.plugins` retiré, sidecar mort. Elle n'est plus sauvegardée par **rien** — son PVC est aussi hors kopia |
| `CNPGMetricsAbsent` | critical | Plus aucune instance scrapée : les six autres sont aveugles d'un coup. Réactivée le 2026-10-16 avec `bankwiz-db` |

> [!WARNING]
> **`CNPGBackupChainAbsent` est la seule règle à nommer les bases en dur**
> (d'où sa mise en commentaire avec le départ de la seule base sauvegardée), parce qu'`absent()`
> perd les labels. **Mettre une base sous
> sauvegarde demande de l'ajouter ici, et rien ne le signale.** Les autres règles s'en dispensent :
> les métriques du plugin n'existent que là où `spec.plugins` est câblé, donc l'intention est
> portée par le `Cluster` lui-même.

`CNPGMetricsAbsent` est formulée en `absent(...)` sur une métrique servie inconditionnellement,
plutôt qu'en `up{job=...}` : le label `job` d'un PodMonitor dépend de la façon dont
prometheus-operator le dérive, et une règle qui vise un `job` inexistant ne se déclenche jamais tout
en paraissant correcte.

## Opérations

- **Vérifier que le scrape fonctionne** — la cible doit être `up`, avec le label `cnpg_io_cluster` :
  ```bash
  kubectl -n cnpg-system get podmonitor cnpg-instances
  # dans l'UI Prometheus : Status → Targets → podMonitor/cnpg-system/cnpg-instances
  ```
  Aucune cible = label `release: kube-prometheus-stack` absent, ou `cnpg.io/podRole: instance` qui
  ne matche plus (à revérifier après une montée majeure de CNPG).

- **Lire l'état de la chaîne à la main**, sans passer par Prometheus :
  ```bash
  # Remplacer <ns> et <cluster> par ceux de la base
  kubectl get --raw "/api/v1/namespaces/<ns>/pods/<cluster>-1:9187/proxy/metrics" \
    | grep -E "archive_status|archiver_failed|^barman_cloud"
  ```
  `^barman_cloud` filtre volontairement sur le préfixe du plugin : les
  `cnpg_collector_*_backup_timestamp` homonymes sont les versions **dépréciées** et ne sont pas
  celles que les règles interrogent.

- **Ajouter une base à la liste blanche** : **décommenter** `CNPGBackupChainAbsent` dans
  `manifests/prometheusrule.yaml` et écrire le sélecteur `cnpg_io_cluster` de la nouvelle base
  (l'exemple laissé en commentaire porte un `<base>` à remplacer). ⚠️ Ce n'est **pas** `CNPGNoBackupYet`, qui n'a aucun sélecteur :
  sa règle est un `== 0` sur toutes les séries, ce que §Le détail des règles explique. C'est le **quatrième** geste de la mise sous sauvegarde
  d'une base (cf. [cnpg-barman-plugin](../cnpg-barman-plugin/README.md) §Opérations).

## Non retenu

- **Un dashboard Grafana.** Sa place est
  [kube-prometheus-stack](../kube-prometheus-stack/README.md), comme pour velero et argocd : le
  câblage côté Grafana appartient au composant qui porte Grafana. Ici on ne pose que ce qui produit
  le signal. Les deux dashboards y vivent désormais — « PostgreSQL — cnpg » et « Sauvegardes
  PostgreSQL — barman-cloud » — et ils consomment le PodMonitor de ce composant : le supprimer les
  vide en même temps qu'il rend les alertes muettes.
- **Des alertes de santé PostgreSQL** (réplication, connexions, taille de base). Ce composant ne
  couvre que la **sauvegarde** — c'est ce qui justifie l'exclusion de velero. Le reste serait un
  ajout confortable, sans rien qui en dépende.
