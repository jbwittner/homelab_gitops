# openbao-monitoring

## Rôle

Volet **post-bootstrap** d'[openbao](../openbao/README.md) : scrape de `/v1/sys/metrics` et
alertes sur la disponibilité du coffre. Aucun de ces objets n'est nécessaire au bootstrap —
c'est toute la raison de la séparation.

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
- `manifests/prometheusrule.yaml` — `openbao.rules` : coffre sans nœud actif (15 min, warning) et
  la même condition à 3 h (critical)
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
  Procédure pour en ajouter : ci-dessous.
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
- **Alerte qui sonne alors que le coffre tourne** : vérifier d'abord que le pod porte bien
  `openbao-active=true` (`kubectl -n openbao get pod openbao-0 --show-labels`) — sans
  `service_registration`, le label n'est jamais posé et la cible n'existe pas.
