# cilium

## Rôle

CNI du cluster, implémentation **Gateway API** et LoadBalancer L2. Remplace kube-proxy
(`kubeProxyReplacement: true`). Fournit la `GatewayClass cilium` consommée par
[`gateway-api`](../gateway-api/README.md). Sans lui, aucun pod ne schedule — c'est le premier
composant du [runbook](../../../doc/runbook-bootstrap.md).

## Fichiers

Cilium tourne sur **tous** les clusters. Ce qui est commun vit dans `common/`, ce qui est propre
à un cluster dans son sous-dossier — seul ce dernier est découvert par le generator git de
l'ApplicationSet, `common/` en est explicitement exclu.

- `cilium.appset.yaml` — ApplicationSet (archétype (b) : chart + `$values` + `manifests/`),
  produit une Application `<cluster>-cilium` par sous-dossier de cluster. Version du chart
  épinglée dans `targetRevision` (SemVer **sans `v`**), commune à tous les clusters.
- `common/helm-values.yaml` — values communes : `kubeProxyReplacement`, `l2announcements`,
  `gatewayAPI`, `k8sServiceHost`/`k8sServicePort` (endpoint apiserver local du nœud),
  `cgroup.autoMount: false` (le cgroup est monté par l'hôte)
- `common/manifests/l2-policy.yaml` — `CiliumL2AnnouncementPolicy`, annonce L2 des IP de LB.
  Identique partout, donc porté une seule fois.
- `<cluster>/manifests/ip-pool.yaml` — `CiliumLoadBalancerIPPool`, la seule ressource réellement
  spécifique : une plage **disjointe** par cluster, `192.168.1.80-84` (bleu-kalecgos),
  `192.168.1.85-89` (bleu-arcanagos) (cf. [doc/reseau.md](../../../doc/reseau.md))
- `<cluster>/manifests/kustomization.yaml` — assemble `../../common/manifests` + `ip-pool.yaml`,
  applique le `namePrefix: <cluster>-` qui donne leurs noms finaux aux deux ressources, et pose
  les labels communs plus `homelab.wittner.tech/cluster: <cluster>`. C'est le seul endroit où le
  nom du cluster est écrit en dur — les manifestes eux-mêmes n'en savent rien.

## Diverger sur un cluster

- **Une value** : créer `<cluster>/helm-values.yaml` avec les seules clés à écraser. Il est
  chargé après `common/helm-values.yaml` et reste facultatif (`ignoreMissingValueFiles`).
- **Une ressource** : l'ajouter à `<cluster>/manifests/` et la référencer dans son
  `kustomization.yaml`. Pour en *modifier* une de `common/`, un `patches:` au même endroit.
- **Un cluster de plus** : créer `<cluster>/manifests/{kustomization.yaml,ip-pool.yaml}` sur le
  modèle d'un existant. Le generator le découvre, rien d'autre à toucher.

## Contraintes

> [!WARNING]
> - **Release Helm `cilium` — ne jamais renommer.** Elle est adoptée du `helm install cilium` du
>   bootstrap ; un autre `releaseName` renommerait toutes les ressources et détruirait le CNI.
> - **Même version de chart** entre le `helm install` du bootstrap et le `targetRevision` de
>   l'Application, sinon l'app diverge dès le premier sync.
> - **Compat Gateway API** : la version des CRDs posées par `gateway-api` est couplée à la
>   version de Cilium — vérifier la table de compatibilité upstream **avant** tout bump, des deux
>   côtés (cf. `../gateway-api/manifests/kustomization.yaml`).
> - `bpf.masquerade` reste **désactivé** : activé, il casse CoreDNS quand le DNS du cluster est
>   forwardé vers l'hôte.
> - `ignoreDifferences` sur le ConfigMap `cilium-config` (le contrôleur y écrit).

## Opérations

- **Upgrade** : bumper `targetRevision` dans `cilium.appset.yaml` (un seul point pour tous les
  clusters), commit, push. Vérifier la matrice
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
