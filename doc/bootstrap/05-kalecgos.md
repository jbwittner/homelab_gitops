# 5. Déclarer kalecgos dans ArgoCD

ArgoCD (malygos) se connecte à l'API de kalecgos (`https://192.168.1.14:6443`) avec le compte `argocd-manager`.

| Fichier | Rôle |
|---|---|
| `clusters/bleu-kalecgos/argocd-manager/manifests/argocd-manager.yaml` | SA `kube-system/argocd-manager`, lié à `cluster-admin`, + Secret de jeton longue durée |
| `clusters/bleu-kalecgos/argocd-manager/argocd-manager.app.yaml` | ArgoCD reprend ce compte ensuite (pas de prune) |
| `clusters/bleu-malygos/argocd/manifests/cluster-bleu-kalecgos.sealed.yaml` | secret de cluster (URL, jeton, CA), label `role=worker` ; modèle : `cluster-bleu-kalecgos.secret.example.yaml` |

## 1. Créer le compte sur kalecgos

```sh
kubectl --context admin@bleu-kalecgos apply --server-side \
  -f clusters/bleu-kalecgos/argocd-manager/manifests
```

## 2. Sceller le secret de cluster

Jeton et CA lus dans le Secret du compte, remplis dans le modèle :

```sh
TOKEN=$(kubectl --context admin@bleu-kalecgos -n kube-system get secret argocd-manager-token -o jsonpath='{.data.token}' | base64 -d) \
CADATA=$(kubectl --context admin@bleu-kalecgos -n kube-system get secret argocd-manager-token -o jsonpath='{.data.ca\.crt}') \
yq '.stringData.config = ({"bearerToken": strenv(TOKEN), "tlsClientConfig": {"caData": strenv(CADATA)}} | @json)' \
  clusters/bleu-malygos/argocd/manifests/cluster-bleu-kalecgos.secret.example.yaml \
  > clusters/bleu-malygos/argocd/manifests/cluster-bleu-kalecgos.secret.yaml

kubeseal --context admin@bleu-malygos -o yaml \
  < clusters/bleu-malygos/argocd/manifests/cluster-bleu-kalecgos.secret.yaml \
  > clusters/bleu-malygos/argocd/manifests/cluster-bleu-kalecgos.sealed.yaml

command rm clusters/bleu-malygos/argocd/manifests/cluster-bleu-kalecgos.secret.yaml
```

Commit + push. `argocd-malygos` pose le secret ; les Applications `*-kalecgos` se synchronisent.

Rotation du jeton : supprimer `kube-system/argocd-manager-token` sur kalecgos (ArgoCD le recrée, Kubernetes le remplit), puis refaire la section 2.

## Vérifier

```sh
kubectl --context admin@bleu-malygos -n argocd get applications   # *-kalecgos Synced / Healthy
```

UI → Settings → Clusters : `bleu-kalecgos` en `Successful`.
