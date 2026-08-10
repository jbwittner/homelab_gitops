---
title: Fiche cluster — bleu-arcanagos
type: fiche-cluster
cluster: bleu-arcanagos
tags: [homelab, wittnerlab, kubernetes, argocd, gitops, cluster, fiche-cluster, wip]
created: 2026-08-09
modified: 2026-08-10
status: wip
---

# Fiche cluster — `bleu-arcanagos`

Valeurs propres à ce cluster. La **procédure** de bootstrap / disaster recovery est générique et
vit dans [runbook-bootstrap.md](../runbook-bootstrap.md).

> [!WARNING]
> **Cluster en cours de construction.** La chaîne app-of-apps est complète (`cluster.yaml`,
> `infra/infra.bootstrap.yaml`, `app/app.bootstrap.yaml`) et deux composants existent
> (`infra/argocd-manager/`, `infra/cilium/`). Il manque :
>
> - le `SealedSecret` de cluster côté hub (`cluster-bleu-arcanagos`) → **le hub ne connaît pas
>   encore ce cluster**, donc les `destination.name: bleu-arcanagos` ne résolvent pas et rien
>   n'est réconcilié. C'est le prérequis de tout le reste ;
> - `infra/gateway-api/`, `infra/cert-manager/`, `infra/cert-manager-config/` → pas d'étape 5 ni 6 ;
> - `infra/sealed-secrets/` et tout `*.sealed.yaml` **local** → étapes 3 et 8 sans objet ;
> - `infra/openebs/` → pas d'étape 7 ;
> - tout composant applicatif (`app/` ne contient que son bootstrap).
>
> Les lignes `— (non défini)` ci-dessous ne sont pas des oublis de documentation : la valeur
> n'existe pas encore dans le repo.

```bash
export CLUSTER=bleu-arcanagos
# export CLUSTER_DOMAIN=…   # non défini : pas de listener ni de wildcard pour ce cluster
```

## Pilotage — spoke du hub `bleu-kalecgos`

Ce cluster n'a **pas d'ArgoCD à lui** : il est piloté à distance par celui de
[`bleu-kalecgos`](bleu-kalecgos.md). Conséquences, valables pour tout composant ajouté ici :

| Élément | Valeur |
|---|---|
| ArgoCD qui réconcilie | celui du hub `bleu-kalecgos`, namespace `argocd` |
| `destination` des `.app.yaml` feuilles | `name: bleu-arcanagos` — **jamais** `name: bleu-kalecgos` |
| `destination` du tier-1 / des tier-2 | le hub (`name: bleu-kalecgos`, ns `argocd`) : ils ne produisent que des `Application` |
| `metadata.name` des Applications | préfixé `bleu-arcanagos-…` — namespace `argocd` partagé avec le hub |
| Identité utilisée | `kube-system/argocd-manager` (`cluster-admin`), cf. [`infra/argocd-manager/README.md`](../../bleu-arcanagos/infra/argocd-manager/README.md) |
| Secret d'enregistrement | `cluster-bleu-arcanagos` dans l'`argocd` du hub, scellé avec la clé **du hub** |

> [!CAUTION]
> Un `.app.yaml` de ce cluster laissé sur `name: bleu-kalecgos` déploierait
> sur le **hub**. Pour `cilium`, cela signifie une collision avec la release `cilium` du hub,
> donc son CNI. Vérifier la `destination` à chaque nouveau composant.

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
| `CiliumLoadBalancerIPPool` | `bleu-arcanagos-pool` — `192.168.1.85` → `192.168.1.89` |
| `CiliumL2AnnouncementPolicy` | `bleu-arcanagos-l2` |
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

Index : [`bleu-arcanagos/README.md`](../../bleu-arcanagos/README.md).

```
infra : argocd-manager, cilium
```

## SealedSecrets

Aucun **dans ce cluster** : pas de contrôleur `sealed-secrets` ici, donc aucune clé propre à
`bleu-arcanagos` à sauvegarder ni à restaurer.

En revanche, un secret de ce cluster vit **côté hub**, scellé avec la clé de `bleu-kalecgos` :

| SealedSecret | Emplacement | Contenu | Source amont |
|---|---|---|---|
| `cluster-bleu-arcanagos` | `bleu-kalecgos/infra/argocd/manifests/` (ns `argocd` du hub) | `server`, `bearerToken`, `caData` | token du SA `kube-system/argocd-manager` de ce cluster |

Le perdre ne perd pas le cluster : le token se relit dans `argocd-manager-token` et se rescelle
(cf. [`infra/argocd-manager/README.md`](../../bleu-arcanagos/infra/argocd-manager/README.md)).

## Vérification

```bash
kubectl get nodes                                        # Ready
kubectl -n kube-system rollout status ds/cilium
kubectl -n kube-system get pods -l k8s-app=kube-dns      # CoreDNS Running
kubectl get ciliumloadbalancerippool bleu-arcanagos-pool
kubectl get ciliuml2announcementpolicy bleu-arcanagos-l2
kubectl -n kube-system get sa argocd-manager             # identité du hub sur ce cluster
```

Depuis le **hub** (`bleu-kalecgos`) :

```bash
kubectl -n argocd get secret cluster-bleu-arcanagos      # enregistrement du spoke
argocd cluster list                                      # bleu-arcanagos en Successful
```
