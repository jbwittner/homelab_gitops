# Homelab gitops

GitOps de deux clusters Kubernetes (`bleu-malygos` infra, `bleu-kalecgos` worker), réconciliés par ArgoCD.

Docs : [architecture](doc/architecture.md) · [arborescence](doc/arborescence.md) · [secrets](doc/secrets.md) · [openbao](doc/openbao.md) · [stockage](doc/stockage.md) · [certificats](doc/certificats.md) · [exposition](doc/exposition.md) · [sauvegardes](doc/sauvegardes.md) · [supervision](doc/supervision.md) · [homepage](doc/homepage.md) · [décisions](doc/decisions.md)

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
