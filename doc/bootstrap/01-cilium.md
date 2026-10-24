# 1. Cilium

Depuis la racine du dépôt, un cluster à la fois :

```sh
# malygos
C=bleu-malygos  CTX=admin@bleu-malygos

# kalecgos
C=bleu-kalecgos CTX=admin@bleu-kalecgos
```

## Installer

Version lue dans `cilium.app.yaml` (tenue à jour par Renovate).

```sh
V=$(yq '.spec.sources[] | select(.chart == "cilium") | .targetRevision' clusters/$C/cilium/cilium.app.yaml)

helm --kube-context $CTX upgrade --install cilium cilium \
  --repo https://helm.cilium.io --version $V -n kube-system \
  -f components/cilium/values.yaml -f clusters/$C/cilium/values.yaml

kubectl --context $CTX apply --server-side -k clusters/$C/cilium/manifests

# l'operator ne voit les CRDs Gateway API qu'au démarrage
kubectl --context $CTX -n kube-system rollout restart deploy/cilium-operator
```

## Vérifier

```sh
kubectl --context $CTX get gatewayclass cilium        # ACCEPTED=True
kubectl --context $CTX get ciliumloadbalancerippool   # DISABLED=false
```

Talos pose `node.kubernetes.io/exclude-from-external-load-balancers` sur les control-planes. Si une IP de LoadBalancer ne répond pas, retirer ce label dans la machine config.
