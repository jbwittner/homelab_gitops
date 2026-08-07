# alloy

## Rôle

**Grafana Alloy** en DaemonSet : lit les fichiers de logs des conteneurs sur le nœud
(`/var/log/pods`, montés en hostPath), les étiquette avec les métadonnées Kubernetes et les pousse
vers [loki](../loki/README.md). Successeur de Promtail (EOL). Ne collecte **que les logs des
pods** : les logs système de Talos (kernel, systemd) demanderaient une modification de la
machineconfig, hors périmètre GitOps de ce repo.

## Fichiers

- `alloy.app.yaml` — Application ArgoCD multi-sources : chart Helm + values (`$values`) +
  `manifests/`.
- `helm-values.yaml` — DaemonSet, montage `/var/log`, exécution en root, ServiceMonitor, et la
  configuration Alloy elle-même (`discovery.kubernetes` → `loki.source.file` → `loki.write`).
- `manifests/namespace.yaml` — namespace `alloy` labellisé **`privileged`** (hostPath).
- `manifests/kustomization.yaml` — assemblage.

## Opérations

### Labels et cardinalité

Les labels envoyés à Loki (`namespace`, `pod`, `container`, `app`, `node`) sont les clés
d'indexation : chaque combinaison crée un flux distinct. Ajouter un label à forte cardinalité
(UID, requête, identifiant de trace) dégrade Loki durablement — pour ce type d'information,
filtrer sur le **contenu** de la ligne dans la requête plutôt que d'en faire un label.

### Debug — aucun log n'arrive dans Grafana

```bash
kubectl -n alloy get ds
kubectl -n alloy logs ds/alloy | grep -i error
kubectl -n alloy port-forward ds/alloy 12345:12345   # UI Alloy : graphe des composants,
                                                     # cibles découvertes, dernières erreurs
```

L'UI Alloy (`http://localhost:12345`) montre chaque composant du pipeline et son état : c'est là
qu'on voit si `local.file_match` ne trouve aucune cible (problème de découverte ou de chemin) ou
si `loki.write` échoue (Loki injoignable, 4xx/5xx).

### Redémarrage et doublons

Les positions de lecture vivent dans `/tmp/alloy`, non persisté : après un redémarrage du pod,
Alloy relit les fichiers depuis le début. Loki écarte les entrées strictement identiques d'un même
flux, donc l'effet visible est limité, mais un pic d'ingestion est normal après un rollout.

### Changer ce qui est collecté

Tout se joue dans le bloc `alloy.configMap.content` de `helm-values.yaml` — par exemple ajouter un
`stage.drop` dans `loki.process` pour écarter des lignes bruyantes, ou un second `loki.write` pour
dupliquer le flux vers un autre backend. Commit, push : le config-reloader recharge sans
redémarrer le pod.
