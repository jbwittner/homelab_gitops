# Décisions

| Décision | Pourquoi | Écarté |
|---|---|---|
| Un seul ArgoCD sur malygos | un point de pilotage pour les deux clusters | un ArgoCD par cluster |
| Applications simples, pas d'ApplicationSet | lisible, versions de chart vues par Renovate | ApplicationSet par label |
| `components/` + `clusters/<nom>/<comp>/`, un seul niveau | inventaire par `ls`, commun écrit une fois | arbo par composant ; sous-dossiers bootstrap/infra/apps |
| SealedSecrets pour le boot seulement | ArgoCD doit lire Git avant qu'OpenBao existe | tout en SealedSecrets ; tout en OpenBao |
| OpenBao + External Secrets pour le reste | un seul coffre, secrets hors Git | SealedSecrets partout |
| OpenEBS LocalPV LVM sur les deux clusters | même stockage partout, quotas et snapshots | Mayastor (hugepages, CPU dédiés) ; hostpath (sans quota) |
| Pas de réplication du stockage | simplicité ; malygos n'a qu'un nœud | Mayastor ×3 sur kalecgos |
| Gateway API de Cilium | déjà activé, pas de contrôleur en plus | Envoy Gateway, Traefik |
| Prometheus agent sur kalecgos → malygos | une seule base de métriques, un seul Grafana | kube-prometheus-stack complet sur chaque cluster |
| ArgoCD et sealed-secrets en kustomize sur URL taguée | une version, suivie par Renovate | chart Helm |
| Unseal OpenBao manuel | pas de KMS ; homelab | auto-unseal |
