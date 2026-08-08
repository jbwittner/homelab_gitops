# cilium

## Rôle

CNI du cluster, implémentation **Gateway API** et LoadBalancer L2. Remplace kube-proxy
(`kubeProxyReplacement: true`). Fournit la `GatewayClass cilium` que consommera `gateway-api`
(composant pas encore déployé sur ce cluster). Sans lui, aucun pod ne schedule — c'est le premier
composant du [runbook](../../../doc/runbook-bootstrap.md)
(cf. [fiche cluster](../../../doc/clusters/bleu-arcanogos.md)).

## Fichiers

- `cilium.app.yaml` — Application (archétype (b) : chart + `$values` + `manifests/`).
  Version épinglée dans `targetRevision` (SemVer **sans `v`**).
- `helm-values.yaml` — source unique des values : `kubeProxyReplacement`, `l2announcements`,
  `gatewayAPI`, `k8sServiceHost`/`k8sServicePort` (endpoint apiserver local du nœud),
  `cgroup.autoMount: false` (le cgroup est monté par l'hôte)
- `manifests/ip-pool.yaml` — `CiliumLoadBalancerIPPool` `192.168.1.85-89`, plage disjointe de
  celle des autres clusters (cf. [doc/reseau.md](../../../doc/reseau.md) et la
  [fiche cluster](../../../doc/clusters/bleu-arcanogos.md))
- `manifests/l2-policy.yaml` — `CiliumL2AnnouncementPolicy`, annonce L2 des IP de LB

## Contraintes

> [!WARNING]
> - **Release Helm `cilium` — ne jamais renommer.** Elle est adoptée du `helm install cilium` du
>   bootstrap ; un autre `releaseName` renommerait toutes les ressources et détruirait le CNI.
> - **Même version de chart** entre le `helm install` du bootstrap et le `targetRevision` de
>   l'Application, sinon l'app diverge dès le premier sync.
> - **Compat Gateway API** : la version des CRDs posées par `gateway-api` est couplée à la
>   version de Cilium — vérifier la table de compatibilité upstream **avant** tout bump, des deux
>   côtés. Le composant `gateway-api` n'est pas encore déployé sur ce cluster.
> - `bpf.masquerade` reste **désactivé** : activé, il casse CoreDNS quand le DNS du cluster est
>   forwardé vers l'hôte.
> - `ignoreDifferences` sur le ConfigMap `cilium-config` (le contrôleur y écrit).

## Opérations

- **Upgrade** : bumper `targetRevision` dans `cilium.app.yaml`, commit, push. Vérifier la matrice
  Gateway API d'abord, et relire les *Upgrade Notes* upstream sur un saut de mineure.
- **Debug** :
  ```bash
  kubectl -n kube-system get pods -l k8s-app=cilium
  kubectl -n kube-system logs ds/cilium
  cilium status                        # CLI cilium, si installée
  ```
- **Gateway API non réconciliée** : vérifier `enable-gateway-api` dans le ConfigMap
  `cilium-config`, puis restart one-shot de `cilium-operator` — geste de bootstrap documenté à
  l'étape 5 du [runbook](../../../doc/runbook-bootstrap.md).
  ```bash
  kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.enable-gateway-api}'
  kubectl -n kube-system rollout restart deployment/cilium-operator
  ```
- **IP de LB non annoncée** : `kubectl get ciliumloadbalancerippool`,
  `kubectl get ciliuml2announcementpolicy`, puis `kubectl -n gateway get gateway shared-gw`.
