---
title: Fiche cluster — bleu-arcanogos
type: fiche-cluster
cluster: bleu-arcanogos
tags: [homelab, wittnerlab, kubernetes, argocd, gitops, cluster, fiche-cluster, wip]
created: 2026-08-09
modified: 2026-08-09
status: wip
---

# Fiche cluster — `bleu-arcanogos`

Valeurs propres à ce cluster. La **procédure** de bootstrap / disaster recovery est générique et
vit dans [runbook-bootstrap.md](../runbook-bootstrap.md).

> [!WARNING]
> **Cluster en cours de construction.** Seul `infra/cilium/` existe. Il manque, dans l'ordre où
> le runbook les exige :
>
> - `bleu-arcanogos/cluster.yaml` (tier-1) et `infra/infra.bootstrap.yaml` (tier-2) → **aucun
>   manifeste de ce cluster n'est découvert par ArgoCD aujourd'hui** ;
> - `bleu-arcanogos/README.md` (index des composants, exigé par
>   [conventions.md](../conventions.md)) ;
> - `infra/argocd/` → **étape 2 et suivantes du runbook impossibles** ;
> - `infra/gateway-api/`, `infra/cert-manager/`, `infra/cert-manager-config/` → pas d'étape 5 ni 6 ;
> - `infra/sealed-secrets/` et tout `*.sealed.yaml` → étapes 3 et 8 sans objet ;
> - `infra/openebs/` → pas d'étape 7 ;
> - `app/` et `app/app.bootstrap.yaml`.
>
> **En l'état, le runbook s'arrête à l'étape 1.** Les lignes `— (non défini)` ci-dessous ne sont
> pas des oublis de documentation : la valeur n'existe pas encore dans le repo.

```bash
export CLUSTER=bleu-arcanogos
# export CLUSTER_DOMAIN=…   # non défini : pas de listener ni de wildcard pour ce cluster
```

## Nœud

Nom du nœud : — (non défini).

`helm-values.yaml` de `cilium` est aujourd'hui **identique** à celui de `bleu-kalecgos`, donc les
mêmes attentes de nœud s'appliquent :

| Attente | Valeur | Consommateur |
|---|---|---|
| Endpoint apiserver local | `localhost:7445` (KubePrism) | `cilium` — `k8sServiceHost`/`k8sServicePort` |
| `/sys/fs/cgroup` monté par l'hôte | `cgroup.autoMount.enabled: false` | `cilium` |
| Modules noyau | — (non défini : pas d'`openebs`) | — |
| PodSecurity | — (non défini) | — |

## Réseau

| Élément | Valeur |
|---|---|
| `CiliumLoadBalancerIPPool` | `bleu-arcanogos-pool` — `192.168.1.85` → `192.168.1.89` |
| `CiliumL2AnnouncementPolicy` | `bleu-arcanogos-l2` |
| IP du LB (`shared-gw`) | — (non défini : pas de `gateway-api`) |
| Listener propre au cluster | — (non défini) |
| Secret TLS du listener | — (non défini) |
| Entrée DNS à créer | — (non défini) |

> [!IMPORTANT]
> La plage `192.168.1.85-89` est **disjointe** de celle de
> [`bleu-kalecgos`](bleu-kalecgos.md) (`.80-84`). Deux clusters annonçant la même IP en L2 sur le
> même réseau rendent le trafic imprévisible : toute nouvelle plage doit rester disjointe.

**Exposé aujourd'hui** : rien.

## Stockage

— (non défini : pas d'`openebs`).

## Composants

Pas d'index `bleu-arcanogos/README.md` à ce jour. Composants présents :

```
infra : cilium
```

## SealedSecrets

Aucun. Donc aucune clé sealed-secrets à sauvegarder ni à restaurer pour ce cluster — jusqu'à ce
que `infra/sealed-secrets/` existe.

## Vérification

```bash
kubectl get nodes                                        # Ready
kubectl -n kube-system rollout status ds/cilium
kubectl -n kube-system get pods -l k8s-app=kube-dns      # CoreDNS Running
kubectl get ciliumloadbalancerippool bleu-arcanogos-pool
kubectl get ciliuml2announcementpolicy bleu-arcanogos-l2
```
