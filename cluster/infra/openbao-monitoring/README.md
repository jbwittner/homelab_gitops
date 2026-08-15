# openbao-monitoring

## Rôle

Volet **post-bootstrap** d'[openbao](../openbao/README.md) : scrape de `/v1/sys/metrics` et
alertes sur la disponibilité **et la sauvegarde** du coffre. Aucun de ces objets n'est nécessaire
au bootstrap — c'est toute la raison de la séparation.

## Pourquoi ce composant existe

Le chart openbao sait générer ce ServiceMonitor
(`serverTelemetry.serviceMonitor.enabled: true`), et c'est ce qui était en place tant qu'openbao
vivait sous `cluster/app/` : le même app-of-apps synchronisait le coffre et
[kube-prometheus-stack](../../app/kube-prometheus-stack/README.md), la CRD était donc là. Le
passage du composant dans `cluster/infra/` a cassé cette relation — les sync-waves ne s'ordonnent
qu'à l'intérieur d'un app-of-apps, `infra` et `app` se déroulent en parallèle — et la doc du
chart est explicite sur ce qui arrive alors :

> The Prometheus operator **must** be installed before enabling this feature, if not the chart
> will fail to install due to missing CustomResourceDefinitions.

Le flag a donc été coupé pour débloquer la sync, et le coffre s'est retrouvé sans supervision.
Le ServiceMonitor est réécrit à la main ici, à l'identique du template : même contenu, mais dans
une Application qui a le droit d'échouer tant que le stack d'observabilité n'est pas là. Même
schéma que [openebs-monitoring](../openebs-monitoring/README.md).

## Fichiers

- `openbao-monitoring.app.yaml` — Application (archétype (c), path → `manifests/`), **wave 2**,
  ns `openbao`
- `manifests/servicemonitor.yaml` — scrape du Service `openbao-active`, `/v1/sys/metrics`,
  `format=prometheus`, 30 s
- `manifests/prometheusrule.yaml` — deux groupes : `openbao.rules` (coffre sans nœud actif —
  15 min warning, la même condition à 3 h critical) et `openbao.backup.rules` (snapshot raft plus
  vieux que 26 h warning, 50 h critical)
- `manifests/kustomization.yaml` — assemblage

## Contraintes

- **Le côté serveur vit dans `openbao/helm-values.yaml`, et les trois morceaux sont
  indissociables** : `unauthenticated_metrics_access = "true"` dans le listener (Prometheus n'a
  pas de token), `prometheus_retention_time` au niveau racine (sans quoi l'endpoint ne sert
  rien), et `service_registration "kubernetes" {}` qui pose le label `openbao-active: "true"` sur
  le pod leader. Retirer l'un des trois vide ce composant de son sens sans qu'aucune sync
  n'échoue.
- **La cible est `openbao-active`, pas `openbao`.** Choix du chart en mode HA, conservé : à 3
  replicas, seul le leader sert des métriques utiles. Conséquence structurante, sur laquelle les
  alertes sont bâties — **coffre scellé ⇒ pas de leader ⇒ plus d'endpoint ⇒ la cible disparaît de
  Prometheus** au lieu de passer `up == 0`. D'où le `absent(up{...} == 1)` des règles : un
  `up == 0` ne lèverait jamais rien.
- **Le label `release: kube-prometheus-stack` est obligatoire** sur les deux objets, sinon
  Prometheus les ignore silencieusement.
- **Aucune règle n'utilise de métrique interne d'OpenBao**, délibérément : les noms `bao_*` /
  `openbao_*` sont un héritage renommé du fork Vault et n'ont pas été vérifiés contre cette
  version. Une alerte écrite sur un nom inexistant ne lève jamais rien et ne le signale pas.
  Les seules sources utilisées sont `up`, synthétisée par Prometheus, et
  `kube_cronjob_status_last_successful_time`, servie par kube-state-metrics. Procédure pour en
  ajouter : ci-dessous.
- **`openbao.backup.rules` n'est pas un confort : c'est la contrepartie du retrait d'openbao du
  périmètre [velero](../velero/README.md).** Le coffre n'a plus qu'une seule chaîne de sauvegarde,
  le CronJob `openbao-snapshot` ; ces deux règles sont ce qui détecte qu'elle s'est arrêtée. Les
  supprimer sans remettre `openbao` dans `includedNamespaces` laisserait le coffre sans sauvegarde
  **et** sans alerte — les deux décisions se tiennent ensemble.
- **Le `or absent(...)` des règles de sauvegarde est load-bearing.**
  `kube_cronjob_status_last_successful_time` est portée par l'objet CronJob : le supprimer
  (`snapshotAgent.enabled: false`, changement de chart) fait disparaître la série, et un
  `time() - x > seuil` seul cesserait de lever quoi que ce soit. Même classe de faux négatif que
  l'`absent(up{...} == 1)` du premier groupe, pour une raison différente. Corollaire au bootstrap :
  un CronJob qui n'a jamais réussi n'a pas de `lastSuccessfulTime`, donc les deux alertes sonnent
  jusqu'au premier snapshot — voulu.
- **Les seuils 26 h / 50 h sont dérivés à la main du `schedule` du CronJob** (`0 3 * * *`, dans
  `openbao/helm-values.yaml`) : un cycle manqué plus 2 h de marge, puis deux cycles. Rien ne relie
  les deux fichiers ; changer le schedule sans changer les seuils passe inaperçu.
- **`port: http`** est le nom du port 8200 du Service tant que `global.tlsDisable: true` (TLS
  terminé au Gateway). En https il se nommerait `https` : les deux champs `port` et `scheme` sont
  à changer ensemble.
- **Le `job` des séries vaut le nom du Service** (`openbao-active`), comportement par défaut du
  prometheus-operator — même convention que la règle d'openebs-monitoring. Un `jobLabel` sur le
  ServiceMonitor changerait cette valeur et casserait silencieusement les deux alertes.

## Opérations

- **Bootstrap à froid** : cette Application reste en erreur tant que kube-prometheus-stack n'est
  pas déployé (CRDs absentes) — attendu, sans conséquence, personne n'attend derrière. Elle se
  répare seule au retry suivant (`selfHeal`). `OpenBaoNoActiveNode` sonnera aussi tant que le
  coffre n'est pas descellé : c'est le comportement voulu, pas un faux positif.
- **Vérifier la chaîne complète** :
  ```bash
  kubectl -n openbao get servicemonitor,prometheusrule --show-labels
  kubectl -n openbao get endpoints openbao-active        # vide ⇒ coffre scellé, pas de cible
  kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
  curl -s 'localhost:9090/api/v1/query?query=up{job="openbao-active"}'
  ```
- **Voir les métriques réellement servies** (la liste dépend de la version d'OpenBao) — à faire
  **coffre descellé**, l'endpoint étant indisponible autrement :
  ```bash
  kubectl -n openbao exec -ti openbao-0 -- \
    wget -qO- 'http://127.0.0.1:8200/v1/sys/metrics?format=prometheus' | grep '^# HELP' | sort
  ```
  C'est la seule base saine pour ajouter une règle sur l'état du raft, les leases ou les tokens :
  copier le nom EXACT vu ici, puis vérifier l'expression dans l'onglet Graph de Prometheus avant
  de la committer.
- **Alerte qui sonne alors que le coffre tourne.** `absent(up{...} == 1)` a deux branches et
  elles n'appellent pas la même action — `bao status` d'abord, jamais `unseal` par réflexe :
  ```bash
  kubectl -n openbao exec openbao-0 -- bao status          # Sealed true ⇒ desceller, point.
  ```
  Si `Sealed false`, le coffre va bien et c'est le **scrape** qui échoue. Lire le motif :
  ```bash
  kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
  curl -s 'localhost:9090/api/v1/targets?state=any' | jq '.data.activeTargets[]
    | select(.labels.job=="openbao-active") | {health, lastError}'
  ```
  - `403 Forbidden` sur `/v1/sys/metrics` ⇒ le process n'a pas
    `unauthenticated_metrics_access` dans la config qu'il a **chargée**. OpenBao lit sa config au
    démarrage et ne la relit pas à chaud (SIGHUP ne couvre que TLS et log level) : une ConfigMap
    à jour dans Git et montée dans le pod ne prouve RIEN. Comparer les dates avant d'accuser
    ArgoCD :
    ```bash
    kubectl -n openbao get pod openbao-0 -o jsonpath='{.status.startTime}{"\n"}'
    kubectl -n openbao get cm openbao-config -o jsonpath='{.metadata.managedFields[*].time}{"\n"}'
    ```
    ConfigMap plus récente que le pod ⇒ `kubectl -n openbao delete pod openbao-0`, **puis
    desceller** (`updateStrategy: OnDelete` sur le StatefulSet, choix du chart : pas de rollout
    automatique justement parce que le descellement est manuel — `kubectl rollout status` est
    inutilisable ici, il refuse tout ce qui n'est pas `RollingUpdate`).
  - **cible absente** de la liste ⇒ vérifier le label `openbao-active=true`
    (`kubectl -n openbao get pod openbao-0 --show-labels`) : sans `service_registration`, il
    n'est jamais posé et le Service n'a pas d'endpoint.

  Vécu le 12→15/08/2026 : `unauthenticated_metrics_access` committé 14 minutes après le
  démarrage du pod, trois jours de 403 sur un coffre parfaitement descellé. `bao operator unseal`
  sur un coffre déjà descellé répond `Sealed false` sans le moindre avertissement — c'est ce qui
  rend ce cas coûteux à diagnostiquer, et pourquoi les descriptions des deux alertes portent
  désormais le départage.
