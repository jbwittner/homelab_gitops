# cilium — bleu-kalecgos

## Rôle

CNI du cluster + implémentation **Gateway API** + LoadBalancer L2. Remplace kube-proxy
(`kubeProxyReplacement: true`). Fournit la `GatewayClass cilium` consommée par
[`gateway-api`](../gateway-api/README.md).

## Source & versions

| Quoi | Valeur |
|---|---|
| Chart | `cilium` — https://helm.cilium.io/ |
| Version épinglée | `1.19.5` (SemVer **sans `v`**) |
| Namespace | `kube-system` |
| Release Helm | `cilium` — ⚠️ **ne jamais changer** (adopté du `helm install cilium` du bootstrap) |
| Archétype | (b) Helm + `$values` + `manifests/` |

La version du chart doit rester **identique** entre le `helm install` du bootstrap (phase 3 du
runbook) et le `targetRevision` de l'Application. Compat Gateway API : Cilium 1.19 → CRDs v1.4.1
(voir matrice dans `../gateway-api/manifests/kustomization.yaml`).

## Fichiers

- `cilium.app.yaml` — Application (3 sources : chart + `$values` + `manifests/`)
- `helm-values.yaml` — source unique des values (kubeProxyReplacement, l2announcements,
  gatewayAPI, k8sServiceHost localhost:7445 — KubePrism Talos)
- `manifests/ip-pool.yaml` — `CiliumLoadBalancerIPPool` `192.168.1.80-84`
- `manifests/l2-policy.yaml` — annonce L2 des IPs LB

## Dépendances & sync-wave

Wave 0. Installé **avant ArgoCD** au bootstrap (`helm install`, phase 3 du runbook) puis adopté
par l'Application. Requis par : tout (CNI). `ignoreDifferences` sur `cilium-config` (le
contrôleur y écrit).

## Opérations courantes

- **Upgrade** : bumper `targetRevision` dans `cilium.app.yaml`, commit, push. ⚠️ Vérifier la
  matrice de compat Gateway API avant.
- **Debug** : `kubectl -n kube-system get pods -l k8s-app=cilium`,
  `kubectl -n kube-system logs ds/cilium`, `cilium status` (CLI).
- **Gateway API pas réconciliée** : vérifier `enable-gateway-api` dans `cilium-config` puis
  restart one-shot de `cilium-operator` (geste documenté phase 5 du runbook).
