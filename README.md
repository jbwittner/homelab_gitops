# Homelab gitops

GitOps de deux clusters Kubernetes (`bleu-malygos` infra, `bleu-kalecgos` worker), réconciliés par ArgoCD.

Docs : [architecture](doc/architecture.md) · [arborescence](doc/arborescence.md) · [secrets](doc/secrets.md) · [openbao](doc/openbao.md) · [authelia](doc/authelia.md) · [stockage](doc/stockage.md) · [certificats](doc/certificats.md) · [exposition](doc/exposition.md) · [sauvegardes](doc/sauvegardes.md) · [supervision](doc/supervision.md) · [homepage](doc/homepage.md) · [renovate](doc/renovate.md) · [décisions](doc/decisions.md)

## Déployé

Une ligne par composant ; Application ArgoCD `<comp>-<cluster-court>`. Versions : dans les `*.app.yaml` (Renovate).

| Composant | Couche | malygos | kalecgos | Namespace | Accès |
|---|---|:---:|:---:|---|---|
| CRDs Gateway API | boot | ✓ | ✓ | — | — |
| CRDs Prometheus Operator | boot | ✓ | ✓ | — | — |
| Cilium (CNI, LB-IPAM, Gateway API) | boot | ✓ | ✓ | `kube-system` | — |
| Sealed Secrets | boot | ✓ | | `kube-system` | — |
| ArgoCD (pilote les deux clusters) + app-of-apps | boot | ✓ | | `argocd` | [argocd](https://argocd.lan.wittner.tech) |
| Compte `argocd-manager` | boot | | ✓ | `kube-system` | — |
| OpenEBS LocalPV LVM | infra | ✓ | ✓ | `openebs` | — |
| cert-manager (Let's Encrypt DNS-01) | infra | ✓ | ✓ | `cert-manager` | — |
| External Secrets | infra | ✓ | ✓ | `external-secrets` | — |
| Gateway `lan` (wildcard `*.lan`) | infra | ✓ `.80` | ✓ `.85` | `gateway` | — |
| OpenBao | infra | ✓ | | `openbao` | [openbao](https://openbao.lan.wittner.tech) |
| Authelia (OIDC : ArgoCD, Grafana) | infra | ✓ | | `authelia` | [auth](https://auth.lan.wittner.tech) |
| Velero (GCS) | infra | ✓ | ✓ | `velero` | — |
| kube-prometheus-stack | infra | ✓ complet | ✓ agent | `monitoring` | [grafana](https://grafana.lan.wittner.tech), [prometheus](https://prometheus.lan.wittner.tech), [alertmanager](https://alertmanager.lan.wittner.tech) |
| external-services (machines du LAN, relais vers kalecgos) | infra | ✓ | | `external-services` | [adguard](https://adguard.lan.wittner.tech), [ha](https://ha.lan.wittner.tech), [pve-ysera](https://pve-ysera.lan.wittner.tech), [z2m](https://z2m.lan.wittner.tech), [zyxel](https://zyxel.lan.wittner.tech), [homepage](https://homepage.lan.wittner.tech) (relais) |
| Homepage | apps | | ✓ | `homepage` | [homepage](https://homepage.lan.wittner.tech) |
| Renovate (CronJob, GitHub App) | apps | | ✓ | `renovate` | — |

Hors dépôt (Proxmox `vert-ysera`) : AdGuard Home (DNS), Home Assistant, Zigbee2MQTT, client NetBird.

## À faire plus tard

Sujets reportés volontairement, à reprendre au besoin.

| Sujet | Quoi | Où |
|---|---|---|
| Alertmanager | aucun destinataire : les alertes ne partent nulle part (mail, Discord, ntfy…) | `clusters/bleu-malygos/kube-prometheus-stack/values.yaml` |
| Control plane Talos | métriques scheduler, controller-manager, etcd servies sur `127.0.0.1` : les ouvrir puis réactiver | `homelab_talos`, puis `components/kube-prometheus-stack/values.yaml` |
| Cilium et Hubble | métriques (agent, opérateur, Envoy, Hubble) + ServiceMonitors ; en option Hubble Relay et UI (`hubble.lan.wittner.tech`) | `components/cilium/values.yaml` |
| Audit OpenBao | journal des accès au coffre | `homelab_terraform`, [openbao](doc/openbao.md) |
| Reloader | redémarrer un pod quand un Secret ESO lu au démarrage change (aujourd'hui : `grafana-admin`, à la main) | nouveau composant |
| Widgets Homepage à identifiants | AdGuard, Proxmox (`PVEAuditor`), Home Assistant : OpenBao → ESO → `HOMEPAGE_VAR_*` (va avec Reloader) | `clusters/bleu-kalecgos/homepage/` |
| Retry ArgoCD | avant un boot à blanc : ArgoCD ne retente que 5 fois, une Application dont une dépendance arrive tard reste en échec | `*.app.yaml` (`syncPolicy.retry`) |
| Restauration OpenBao en prod | remise en place d'un snapshot raft (`-force`) jamais testée ; la restauration à côté l'est | [sauvegardes](doc/sauvegardes.md) |
| NetBird | second peer routeur dans un cluster, en redondance du CT Proxmox | — |
| OIDC : autres clients | OpenBao (méthode `oidc`), Proxmox (realm OpenID) ; client dans `clients.yml` | [authelia](doc/authelia.md) |
| Prometheus, Alertmanager sans authentification | pas de forward-auth sur le Gateway Cilium : oauth2-proxy devant chacun | `clusters/bleu-malygos/kube-prometheus-stack/` |
