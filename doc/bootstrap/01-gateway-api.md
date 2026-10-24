# 1. Gateway API

CRDs Gateway API. Avant Cilium : le chart ne crée la GatewayClass `cilium` que si les CRDs existent, et l'operator ne les voit qu'à son démarrage. L'API server répond sans CNI.

Depuis la racine du dépôt, un cluster à la fois :

```sh
# malygos
C=bleu-malygos  CTX=admin@bleu-malygos

# kalecgos
C=bleu-kalecgos CTX=admin@bleu-kalecgos
```

## Installer

```sh
kubectl --context $CTX apply --server-side -k components/gateway-api/manifests
```

## Vérifier

```sh
kubectl --context $CTX get crd | rg gateway.networking   # 10 CRDs
```
