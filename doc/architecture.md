# Architecture

## Clusters

| | `bleu-malygos` | `bleu-kalecgos` |
|---|---|---|
| Rôle | infra (critique) | worker |
| Label ArgoCD | `role=infra` | `role=worker` |
| Nœuds | `vert-emeriss` .15 | `vert-eranikus` .11, `vert-itharius` .12, `vert-ysondre` .13 |
| Plage LB-IPAM | `192.168.1.80-82` | `192.168.1.85-89` |

Talos 1.13, Kubernetes 1.36, Cilium 1.20 (kube-proxy replacement, L2 announcements, Gateway API).

## Composants

| Composant | malygos | kalecgos |
|---|:---:|:---:|
| Cilium | ✓ | ✓ |
| CRDs Gateway API + `Gateway` partagé | ✓ | ✓ |
| CRDs Prometheus Operator (bootstrap) | ✓ | ✓ |
| OpenEBS LocalPV LVM (VG `openebs-vg`, [stockage](stockage.md)) | ✓ | ✓ |
| cert-manager (wildcard `*.lan.wittner.tech`) | ✓ | ✓ |
| External Secrets | ✓ | ✓ |
| Velero ([sauvegardes](sauvegardes.md)) | ✓ | ✓ |
| Sealed Secrets (boot) | ✓ | |
| ArgoCD | ✓ | |
| OpenBao | ✓ | |
| kube-prometheus-stack complet | ✓ | |
| Prometheus agent (remote-write) | | ✓ |
| Workloads | | ✓ |

## Flux

```
                 bleu-malygos                          bleu-kalecgos
            ┌──────────────────────┐              ┌──────────────────────┐
  GitHub ──►│ ArgoCD ──────────────┼── déploie ──►│                      │
            │                      │              │                      │
            │ OpenBao ◄────────────┼── ESO ───────┤ External Secrets     │
            │                      │              │                      │
            │ Prometheus ◄─────────┼─ remote-write┤ Prometheus agent     │
            └──────────┬───────────┘              └──────────┬───────────┘
                       │ Gateway .80                         │ Gateway .85
                       └──────── DNS AdGuard 192.168.1.2 ────┘
                  (*.lan.wittner.tech → .80 ; rewrite exact → .85)
```

## Limites connues

- malygos a un seul nœud : s'il tombe, plus de déploiement, de secrets neufs ni de monitoring. kalecgos continue de tourner.
- LVM sans réplication : un volume vit sur un seul nœud.
