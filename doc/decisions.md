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
| ArgoCD en kustomize sur URL taguée (exception à « Helm en priorité ») | plus simple à surcharger : patches sur les manifestes officiels ; une version suivie par Renovate | chart Helm `argo/argo-cd` |
| sealed-secrets en chart Helm + values | même schéma que Cilium ; un réglage (`keyrenewperiod`) sans patch | kustomize sur URL + patch JSON |
| Namespace = celui de la doc upstream (Cilium, sealed-secrets : `kube-system` ; OpenEBS : `openebs`…) | CLI et procédures upstream sans `-n` ; `kube-system` exempté de PSA par Talos | un namespace dédié partout |
| Accès Git d'ArgoCD par GitHub App (`repo-creds` sur `https://github.com/jbwittner`) | survit au passage du dépôt en privé ; URLs HTTPS inchangées ; lecture seule, jetons d'1 h | anonyme ; deploy key SSH (URLs à changer, une clé par dépôt) ; PAT (expire) |
| Secrets de cluster dans le kustomize d'ArgoCD (`clusters/bleu-malygos/argocd/manifests`) | un seul `apply -k` au boot ; l'app-of-apps ne charge que des `*.app.yaml` | `cluster.yaml` à la racine de chaque cluster, chargé par l'app-of-apps |
| Une app-of-apps par cluster (`clusters/<nom>/apps.app.yaml`) | dans l'UI, tout ce qui est déployé sur un cluster est sous une seule Application | une app racine sur `clusters/**` |
| Nom d'Application `<comp>-<cluster-court>` | un composant sur tous ses clusters côte à côte dans la liste ; la vue par cluster vient du filtre « Clusters » de l'UI | `<cluster-court>-<comp>` |
| Mot de passe admin ArgoCD en SealedSecret `patch` sur `argocd-secret` | déclaratif, survit à une réinstallation ; `patch` garde les clés écrites par ArgoCD | changement manuel (perdu à la réinstallation) ; ESO `Merge` (attend OpenBao) |
| Compte `argocd-manager` de kalecgos versionné (`cluster-admin`, jeton longue durée), repris par ArgoCD | même compte que `argocd cluster add`, mais déclaratif ; jeton régénérable en supprimant son Secret | `argocd cluster add` (impératif, hors Git) |
| Unseal OpenBao manuel | pas de KMS ; homelab | auto-unseal |
| Rotation de clé sealed-secrets désactivée | une seule sauvegarde reste valable ; secrets de boot seulement | rotation 30 j + sauvegarde à chaque rotation |
