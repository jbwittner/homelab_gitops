# Décisions

| Décision | Pourquoi | Écarté |
|---|---|---|
| Un seul ArgoCD sur malygos | un point de pilotage pour les deux clusters | un ArgoCD par cluster |
| Applications simples, pas d'ApplicationSet | lisible, versions de chart vues par Renovate | ApplicationSet par label |
| `components/` + `clusters/<nom>/<comp>/`, un seul niveau | inventaire par `ls`, commun écrit une fois | arbo par composant ; sous-dossiers bootstrap/infra/apps |
| SealedSecrets pour le boot seulement | ArgoCD doit lire Git avant qu'OpenBao existe | tout en SealedSecrets ; tout en OpenBao |
| OpenBao + External Secrets pour le reste | un seul coffre, secrets hors Git | SealedSecrets partout |
| OpenEBS LocalPV LVM sur les deux clusters | même stockage partout, quotas et snapshots | Mayastor (hugepages, CPU dédiés) ; hostpath (sans quota) |
| OpenEBS en chart parapluie `openebs`, LVM seul | chemin d'install upstream ; un autre moteur = un `enabled: true` | chart `lvm-localpv` seul (même rendu) |
| VG `openebs-vg` créé par un DaemonSet (`vg-bootstrap`) | dans Git, idempotent, couvre un nœud ajouté ou réinstallé | `kubectl debug node` + `vgcreate` à la main |
| StorageClass thick + `Retain` | thin : pool créé à la taille du 1er volume, jamais étendu (pas de `dmeventd` sur Talos) ; Retain : un PVC supprimé par erreur se récupère | thin ; `Delete` |
| Pas de réplication du stockage | simplicité ; malygos n'a qu'un nœud | Mayastor ×3 sur kalecgos |
| cert-manager + DNS-01 sur les deux clusters, jeton DNS lu dans OpenBao par ESO | clusters symétriques ; kalecgos renouvelle même malygos en panne (jeton déjà copié) ; chaque cluster sert son certificat | wildcard émis sur malygos et recopié via OpenBao (`PushSecret`) |
| Gateway API de Cilium | déjà activé, pas de contrôleur en plus | Envoy Gateway, Traefik |
| Prometheus agent sur kalecgos → malygos | une seule base de métriques, un seul Grafana | kube-prometheus-stack complet sur chaque cluster |
| ArgoCD en kustomize sur URL taguée (exception à « Helm en priorité ») | plus simple à surcharger : patches sur les manifestes officiels ; une version suivie par Renovate | chart Helm `argo/argo-cd` |
| sealed-secrets en chart Helm + values | même schéma que Cilium ; un réglage (`keyrenewperiod`) sans patch | kustomize sur URL + patch JSON |
| Namespace = celui de la doc upstream (Cilium, sealed-secrets : `kube-system` ; OpenEBS : `openebs`…) | CLI et procédures upstream sans `-n` ; `kube-system` exempté de PSA par Talos | un namespace dédié partout |
| Accès Git d'ArgoCD par GitHub App (`repo-creds` sur `https://github.com/jbwittner`) | survit au passage du dépôt en privé ; URLs HTTPS inchangées ; lecture seule, jetons d'1 h | anonyme ; deploy key SSH (URLs à changer, une clé par dépôt) ; PAT (expire) |
| Secrets de cluster dans le kustomize d'ArgoCD (`clusters/bleu-malygos/argocd/manifests`) | un seul `apply -k` au boot ; l'app-of-apps ne charge que des `*.app.yaml` | `cluster.yaml` à la racine de chaque cluster, chargé par l'app-of-apps |
| Une app-of-apps par cluster (`clusters/<nom>/apps.app.yaml`) | dans l'UI, tout ce qui est déployé sur un cluster est sous une seule Application | une app racine sur `clusters/**` |
| Nom d'Application `<comp>-<cluster-court>` | un composant sur tous ses clusters côte à côte dans la liste ; la vue par cluster vient du filtre « Clusters » de l'UI | `<cluster-court>-<comp>` |
| Label `layer: boot\|infra\|apps` sur les Applications | filtre « Labels » de l'UI : le socle d'un coup d'œil ; le cluster vient déjà du filtre « Clusters » | labels `cluster`, `component` ; tags Git en `targetRevision` |
| Mot de passe admin ArgoCD en SealedSecret `patch` sur `argocd-secret` | déclaratif, survit à une réinstallation ; `patch` garde les clés écrites par ArgoCD | changement manuel (perdu à la réinstallation) ; ESO `Merge` (attend OpenBao) |
| Compte `argocd-manager` de kalecgos versionné (`cluster-admin`, jeton longue durée), repris par ArgoCD | même compte que `argocd cluster add`, mais déclaratif ; jeton régénérable en supprimant son Secret | `argocd cluster add` (impératif, hors Git) |
| OpenBao en raft à 1 réplica, sans PDB | snapshots raft ; le PDB du chart (`maxUnavailable: 0`) bloquerait le drain de malygos | mode standalone (pebbledb, sans snapshot raft) |
| Structure d'OpenBao en Terraform (`homelab_terraform/openbao/bleu-malygos`), provider `hashicorp/vault` | plan/diff avant changement ; state GCS déjà en place ; aucune valeur de secret dans le state | commandes `bao` documentées ; auto-init déclarative (premier démarrage seulement) |
| Velero sur GCS, un bucket et un compte par cluster, Workload Identity Federation | aucun secret, donc pas de boucle avec OpenBao qu'il sauvegarde ; hors site ; kalecgos ne touche pas aux sauvegardes de malygos | clé JSON (à stocker : SealedSecret ou OpenBao) ; S3 local (sur site) |
| Volumes sauvegardés par copie de fichiers (Kopia), OpenBao via hook `raft snapshot` | lvm-localpv ne restaure pas un snapshot thick (pas de data mover CSI) ; copie à chaud de raft non fiable | snapshots CSI ; copie brute d'OpenBao |
| Unseal OpenBao manuel, Shamir 1 part / seuil 1 | pas de KMS ; un seul opérateur, un seul gestionnaire de mots de passe : plus de parts n'ajoutent rien | auto-unseal ; 5 parts / seuil 3 |
| Rotation de clé sealed-secrets désactivée | une seule sauvegarde reste valable ; secrets de boot seulement | rotation 30 j + sauvegarde à chaque rotation |
| TLS terminé au Gateway (wildcard `*.lan.wittner.tech`), services en HTTP derrière | un certificat par cluster ; ArgoCD et OpenBao sans TLS à gérer | TLS de bout en bout (`TLSRoute`, `BackendTLSPolicy`) |
| Diff ArgoCD côté serveur (`controller.diff.server.side`) | valeurs par défaut de l'API (HTTPRoute…) pas vues comme un écart ; va avec ServerSideApply | annotation par Application ; `ignoreDifferences` |
| Machines du LAN derrière le Gateway de malygos : Service sans selector + `EndpointSlice` dans Git (`external-services`) ; `EndpointSlice` retiré des exclusions d'ArgoCD sur malygos | Kubernetes standard, mêmes routes que les services internes ; Proxmox (HTTPS) vérifié par `BackendTLSPolicy` + CA PVE | `ExternalName` (non géré par le Gateway Cilium) ; proxy nginx dans le cluster ; skip-verify (absent de Gateway API) |
| DNS AdGuard : `*.lan.wittner.tech` → Gateway de malygos (`.80`), rewrite exact vers kalecgos (`.85`) au besoin | un saut de moins, plus rien à déclarer par hostname sur malygos ; machines du LAN servies par `external-services` | proxy Traefik 192.168.1.50 devant les Gateways |
| NetBird : client (peer routeur du LAN) sur Proxmox, hors des clusters | accès distant intact quand un cluster tombe, c'est lui qui sert à le réparer ; peu de config, GitOps sans gain | NetBird dans le cluster (seul) ; plus tard, second peer routeur dans le cluster pour la redondance |
| cloudflared pas migré tant qu'il n'expose rien | aucun hostname public aujourd'hui ; s'il resert : dans le cluster, tunnel géré localement (règles dans Git), identifiants dans OpenBao | migrer un tunnel vide ; tunnel géré depuis le dashboard Cloudflare |
| CRDs Prometheus Operator dans une Application à part (`prometheus-operator-crds`), posées au bootstrap ; moniteurs déclarés par chaque composant | une CRD absente fait échouer toute la synchro d'une Application : avec les CRDs posées d'abord, un moniteur peut vivre avec son composant (option du chart, Helm en priorité), même ArgoCD au boot | CRDs par kube-prometheus-stack et moniteurs regroupés dedans ou dans une Application `monitoring` à part ; `SkipDryRunOnMissingResource` + retry |
| Homepage en manifestes simples sur l'image officielle (exception à « Helm en priorité ») | pas de chart officiel ; Deployment + Service + HTTPRoute lisibles directement ; tag d'image suivi par Renovate dans `manifests/` | chart communautaire `jameswynn` (abandonné, figé en 2025) ; chart générique `app-template` (bjw-s) |
| Homepage sur kalecgos, `homepage.lan.wittner.tech` relayé par malygos (`external-services` → Gateway kalecgos en HTTPS), liens statiques | page d'accueil, pas de l'infra ; l'intégration Kubernetes ne verrait que kalecgos ; relais : rien à déclarer hors dépôt | malygos ; mode `cluster` (découverte des HTTPRoute) ; rewrite AdGuard exact (n'a pas pris le pas sur le wildcard) |
