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
> **Cluster en cours de construction.** Il est **enregistré** dans le hub (SealedSecret
> `cluster-bleu-arcanagos`, référencé dans le kustomize d'ArgoCD) et porte deux composants :
> [`infra/argocd-manager/bleu-arcanagos/`](../../cluster/infra/argocd-manager/README.md) et
> [`infra/cilium/bleu-arcanagos/`](../../cluster/infra/cilium/README.md), tous deux générés par
> `ApplicationSet`. Il manque, dans l'ordre où ça bloquerait :
>
> - `gateway-api` — c'est aujourd'hui une `Application` **mono-cluster** (le hub) : il faut la
>   migrer en `ApplicationSet` pour donner un `Gateway` à ce cluster → pas d'étape 5 ni 6 ;
> - `cert-manager` / `cert-manager-config` — idem, aucun certificat ici ;
> - `openebs` → pas d'étape 7, aucune StorageClass, tout PVC resterait `Pending` ;
> - `sealed-secrets` → pas de contrôleur local ; aucun `SealedSecret` ne peut être consommé **sur
>   ce cluster** (étapes 3 et 8 sans objet ici) ;
> - tout composant applicatif : aucun dossier de `cluster/app/` ne désigne ce cluster.
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
| `destination` des feuilles | `name: bleu-arcanagos` — **jamais** `name: bleu-kalecgos` |
| `destination` du tier-1 / des tier-2 | le hub (`name: bleu-kalecgos`, ns `argocd`) : ils ne produisent que des `Application`/`ApplicationSet` |
| `metadata.name` des Applications | préfixé `bleu-arcanagos-…` (posé par le template de l'appset) — namespace `argocd` partagé avec le hub |
| Label de sélection | `homelab.wittner.tech/cluster: bleu-arcanagos` |
| Identité utilisée | `kube-system/argocd-manager` (`cluster-admin`), cf. [`argocd-manager/README.md`](../../cluster/infra/argocd-manager/README.md) |
| Secret d'enregistrement | `cluster-bleu-arcanagos` dans l'`argocd` du hub, scellé avec la clé **du hub** |
| Endpoint apiserver | `https://192.168.1.12:6443` (valeur `server` du Secret de cluster) |

> [!CAUTION]
> Un composant de ce cluster laissé sur `name: bleu-kalecgos` déploierait sur le **hub**. Pour
> `cilium`, cela signifie une collision avec la release `cilium` du hub, donc son CNI. Sur un
> `ApplicationSet`, la cible vient du nom du **dossier** (`{{.path.basename}}`) : le piège se
> déplace vers le nommage des dossiers, à vérifier à chaque ajout.

## Nœud

Nom du nœud : — (non défini).

Ce cluster n'a **pas** de `helm-values.yaml` propre pour `cilium` : il consomme uniquement
[`common/helm-values.yaml`](../../cluster/infra/cilium/common/helm-values.yaml), donc les mêmes
attentes de nœud que le hub s'appliquent.

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
| `CiliumL2AnnouncementPolicy` | `bleu-arcanagos-l2` (depuis `common/manifests/l2-policy.yaml`) |
| IP du LB | — (non défini : aucun Service `LoadBalancer`, pas de `gateway-api`) |
| Listener propre au cluster | — (non défini) |
| Secret TLS du listener | — (non défini) |
| Entrée DNS à créer | — (non défini) |

Les deux noms viennent du `namePrefix: bleu-arcanagos-` de
[`cluster/infra/cilium/bleu-arcanagos/manifests/kustomization.yaml`](../../cluster/infra/cilium/bleu-arcanagos/manifests/kustomization.yaml).

> [!IMPORTANT]
> La plage `192.168.1.85-89` est **disjointe** de celle de
> [`bleu-kalecgos`](bleu-kalecgos.md) (`.80-84`). Deux clusters annonçant la même IP en L2 sur le
> même réseau rendent le trafic imprévisible : toute nouvelle plage doit rester disjointe.

**Exposé aujourd'hui** : rien.

## Stockage

— (non défini : pas d'`openebs`).

## Composants

Index : [`README.md`](../../README.md) racine.

Applications attendues dans ArgoCD (côté **hub**, ns `argocd`) :

```
bleu-arcanagos-argocd-manager     # wave -20 de l'appset, prune: false, sans finalizer
bleu-arcanagos-cilium
```

```bash
kubectl -n argocd get app -l homelab.wittner.tech/cluster=bleu-arcanagos
```

## SealedSecrets

Aucun **dans ce cluster** : pas de contrôleur `sealed-secrets` ici, donc aucune clé propre à
`bleu-arcanagos` à sauvegarder ni à restaurer.

En revanche, un secret de ce cluster vit **côté hub**, scellé avec la clé de `bleu-kalecgos` :

| SealedSecret | Emplacement | Contenu | Source amont |
|---|---|---|---|
| `cluster-bleu-arcanagos` | [`cluster/infra/argocd/manifests/`](../../cluster/infra/argocd/manifests/) (ns `argocd` du hub) | `name`, `server`, `config` (bearerToken + caData) | token du SA `kube-system/argocd-manager` de ce cluster |

Le perdre ne perd pas le cluster : le token se relit dans `argocd-manager-token` et se rescelle
(cf. [`argocd-manager/README.md`](../../cluster/infra/argocd-manager/README.md)).

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
kubectl -n argocd get secret cluster-bleu-arcanagos      # enregistrement du spoke (déchiffré)
kubectl -n argocd get app -l homelab.wittner.tech/cluster=bleu-arcanagos
argocd cluster list                                      # bleu-arcanagos en Successful
```
