# kubevirt

> [!IMPORTANT]
> **ARCHIVÉ le 2026-10-22.** Fichier `kubevirt.noapp.yaml` : non déployé depuis le 2026-09-25
> (commit `291f61e`).
>
> Il n'a plus aucun consommateur : la seule VM qu'il faisait tourner a été retirée du dépôt. Le
> `path:` de l'Application pointe toujours `cluster/infra/kubevirt/manifests`, qui n'existe plus —
> les manifestes sont à côté de ce fichier. ⚠️ Pour le remettre en service : le ramener sous
> `cluster/infra/` (la wave 1 n'ordonne CDI après `openebs` qu'**à l'intérieur** de l'app-of-apps
> `infra`), corriger `path:`, puis renommer en `.app.yaml`.

## Rôle

Hyperviseur du cluster : KubeVirt fait tourner des machines virtuelles comme des pods, CDI importe
leurs images disque dans des PVC.

## Fichiers

- `kubevirt.noapp.yaml` — Application (archétype (c) : kustomize seul), **wave 1**. Même wave que
  [velero](../../cluster/infra/velero/README.md) et pour la même raison : CDI a besoin d'une StorageClass, donc
  d'[openebs](../../cluster/infra/openebs/README.md) qui est en wave 0 du même app-of-apps.
- `manifests/kustomization.yaml` — les **quatre** installs upstream épinglés par URL (opérateur +
  CR, pour KubeVirt et pour CDI), et les deux `patches` qui les configurent. Ces URLs sont la
  source unique des deux versions.

## Contraintes

- **Les deux `*-cr.yaml` sont en sync-wave de ressource `1`, les opérateurs en wave par défaut.**
  Un `KubeVirt` ou un `CDI` appliqué avant son opérateur échoue sur `no matches for kind` et met
  l'Application entière en erreur. La wave est posée par `patches`, pas par l'ordre de
  `resources:` — kustomize ne garantit aucun ordre d'application.
- **`evictionStrategy: None`, imposé par le stockage.** `openebs-lvm-thin` est node-local et RWO :
  une VM est clouée au nœud qui porte son volume, la migration à chaud est impossible. Sans ce
  réglage, un `kubectl drain` reste bloqué indéfiniment sur une migration qui ne peut pas aboutir.
  ⚠️ Conséquence à connaître : **drainer un nœud éteint les VM qui y tournent**. Acceptable pour
  un composant d'exercice, à revoir le jour où une VM porte de l'exploitation.
- **Le namespace `kubevirt` est labellisé `privileged` par l'install upstream ; `cdi` ne l'est
  pas.** C'est voulu côté upstream — CDI est conçu pour tourner sous PSA `restricted`. Talos
  impose `baseline` à tout le cluster : si un jour un pod `cdi-importer` est rejeté à l'admission,
  c'est là qu'il faut regarder, **pas** dans la StorageClass.
- **`/dev/kvm` doit exister sur les nœuds.** Vérifié sur `bleu-kalecgos` (CPU Intel `vmx`, KVM
  compilé dans le noyau Talos — pas de module à charger, donc rien à ajouter à la machineconfig).
  Sans lui, `virt-handler` n'annonce pas la ressource `devices.kubevirt.io/kvm` et toute VM reste
  `Pending` sur un `Insufficient devices.kubevirt.io/kvm` — message qui ne dit pas qu'il s'agit de
  virtualisation.
- **KubeVirt et CDI se versionnent séparément**, sans matrice de compatibilité publiée. Renovate
  propose les deux bumps indépendamment ; rien n'oblige à les merger ensemble.

## Opérations

`virtctl` est le client de KubeVirt. Il ne remplace pas `kubectl`, il ajoute console série, VNC et
port-forward — les trois choses qu'un pod ne sait pas faire.

```bash
# installation du client (macOS, Homebrew) — ce n'est pas un composant du cluster
brew install virtctl

# l'hyperviseur est-il debout : les deux CR doivent être `Deployed` / `Deployed`
kubectl -n kubevirt get kubevirt kubevirt -o jsonpath='{.status.phase}{"\n"}'
kubectl get cdi cdi -o jsonpath='{.status.phase}{"\n"}'

# les nœuds annoncent-ils KVM — une ligne par nœud, valeur attendue non nulle
kubectl get nodes -o custom-columns=NAME:.metadata.name,KVM:.status.allocatable.devices\\.kubevirt\\.io/kvm

# ce qui tourne
kubectl get vm,vmi -A
```
