# cilium

## Rôle

CNI du cluster + implémentation **Gateway API** + LoadBalancer L2. Remplace kube-proxy.
Fournit la `GatewayClass cilium` consommée par [`gateway-api`](../gateway-api/README.md).

## Fichiers

- `cilium.app.yaml` — Application (archétype (b) : chart + `$values` + `manifests/`).
  Version épinglée dans `targetRevision` (SemVer **sans `v`**).
- `helm-values.yaml` — source unique des values (kubeProxyReplacement, l2announcements,
  gatewayAPI, k8sServiceHost — KubePrism Talos)
- `manifests/ip-pool.yaml` — `CiliumLoadBalancerIPPool` (cf. [doc/reseau.md](../../../doc/reseau.md))
- `manifests/l2-policy.yaml` — annonce L2 des IPs LB

## Contraintes

- **Release Helm `cilium` — ne jamais changer** : adoptée du `helm install cilium` du bootstrap.
- **Version chart identique** entre le `helm install` du bootstrap (phase 3 du runbook) et le
  `targetRevision` de l'Application.
- Compat Gateway API : matrice dans `../gateway-api/manifests/kustomization.yaml` — vérifier
  avant tout upgrade.
- `ignoreDifferences` sur `cilium-config` (le contrôleur y écrit).

## Opérations

- **Upgrade** : bumper `targetRevision` dans `cilium.app.yaml`, commit, push. ⚠️ Matrice de
  compat Gateway API d'abord.
- **Debug** : `kubectl -n kube-system get pods -l k8s-app=cilium`,
  `kubectl -n kube-system logs ds/cilium`, `cilium status` (CLI).
- **Gateway API pas réconciliée** : vérifier `enable-gateway-api` dans `cilium-config` puis
  restart one-shot de `cilium-operator` (geste documenté phase 5 du runbook).
