# cnpg

## Rôle

Opérateur **CloudNativePG** : gestion déclarative de clusters PostgreSQL (CRD
`postgresql.cnpg.io/Cluster`). Ne déploie **que l'opérateur** ; les instances PostgreSQL sont
déclarées par les applications consommatrices — aujourd'hui
[`forgejo`](../forgejo/README.md), [`authentik`](../../../archive/authentik/README.md) et
[`test-nginx`](../../../archive/test-nginx/README.md).

## Fichiers

- `cnpg.app.yaml` — Application (archétype (a) : Helm + `$values`), ns `cnpg-system`
- `helm-values.yaml` — `replicaCount: 1` (mono-nœud)

## Composants frères

- [`cnpg-barman-plugin`](../cnpg-barman-plugin/README.md) — sauvegarde native vers stockage objet
  (sauvegardes de base + archivage WAL, donc PITR). Composant à part parce que l'amont l'a séparé :
  depuis CloudNativePG **1.26**, barman-cloud est **sorti de l'opérateur**
  (`spec.backup.barmanObjectStore` déprécié puis retiré) au profit d'un plugin CNPG-I.
- [`cnpg-monitoring`](../cnpg-monitoring/README.md) — PodMonitor + alertes sur l'état de cette
  chaîne. **Load-bearing** : les PVC des bases CNPG sont exclus de la copie kopia de velero, ces
  alertes sont ce qui rend l'exclusion défendable.
- [`kube-prometheus-stack`](../kube-prometheus-stack/README.md) — porte le dashboard
  « PostgreSQL — cnpg » (`manifests/dashboard-cnpg.yaml`), qui lit le PodMonitor de
  `cnpg-monitoring` et les CRs `Cluster` exposés par kube-state-metrics. ⚠️ Les métriques de
  l'opérateur lui-même ne sont **pas** scrapées : `helm-values.yaml` n'active pas
  `monitoring.podMonitorEnabled`, et l'activer ne suffirait pas — le PodMonitor rendu par le chart
  ne porte pas le label `release: kube-prometheus-stack` qu'attend le sélecteur de Prometheus.
  Ce que le dashboard sait dire de l'opérateur vient donc de kube-state-metrics et de cadvisor.

## Contraintes

- **Aucun `Cluster` ne se déclare ici.** Une base vit dans le dossier de l'application qui la
  consomme, avec son cycle de vie.
- **Une base n'est PAS sauvegardée par défaut**, et rien ne le signale. Il faut un `ObjectStore`,
  un `spec.plugins` sur le `Cluster`, une `ScheduledBackup` et une entrée dans la liste blanche de
  `CNPGBackupChainAbsent` — quatre gestes, détaillés dans
  [`cnpg-barman-plugin`](../cnpg-barman-plugin/README.md) §Opérations. Aujourd'hui `forgejo-db` est
  le **seul** `Cluster` du dépôt, et il est couvert.
- **`kubectl get backups` ne montre PAS les sauvegardes velero mais celles de CNPG.** Le nom court
  est ambigu entre `backups.postgresql.cnpg.io` et `backups.velero.io`, et kubectl tranche
  silencieusement en faveur de CNPG. Écrire le nom long des deux côtés.
- L'opérateur génère lui-même le service `<cluster>-rw` et le secret `<cluster>-app` (identifiants
  applicatifs) : les consommateurs les référencent par `secretKeyRef`, ils ne sont jamais scellés.

## Opérations

- **Upgrade** : bumper `targetRevision` dans `cnpg.app.yaml`, commit, push.
- **Créer une base** : déclarer un `Cluster` dans le `manifests/` de l'app consommatrice.
- **Debug** :
  ```bash
  kubectl -n cnpg-system logs deploy/cnpg-cloudnative-pg
  kubectl get clusters.postgresql.cnpg.io -A
  kubectl -n <ns> describe cluster <name>      # events : bootstrap, failover, backup
  ```
