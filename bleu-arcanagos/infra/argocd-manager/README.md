# argocd-manager

## Rôle

Identité avec laquelle l'ArgoCD du **hub** (`bleu-kalecgos`) pilote ce cluster à distance :
un `ServiceAccount` `kube-system/argocd-manager`, son binding `cluster-admin`, et le token
non expirant que porte le Secret de cluster côté hub. Sans lui, aucune Application de
`bleu-arcanagos/` ne peut être réconciliée.

## Fichiers

- `argocd-manager.app.yaml` — Application (archétype (c) : kustomize seul), wave `-20`,
  `destination.name: bleu-arcanagos` (cluster distant), même `path` que l'apply manuel du
  bootstrap → adoption immédiate
- `manifests/serviceaccount.yaml` — le SA `kube-system/argocd-manager`
- `manifests/clusterrolebinding.yaml` — binding vers `cluster-admin`
- `manifests/argocd-manager-token.yaml` — Secret `kubernetes.io/service-account-token`
  **sans données** ; le token controller le remplit dans le cluster

## Contraintes

> [!WARNING]
> - **`prune: false` et pas de finalizer `resources-finalizer`.** Supprimer ces ressources
>   couperait l'accès du hub au cluster — et ArgoCD, privé de credential, ne pourrait pas
>   terminer la suppression : Application bloquée sur son finalizer.
> - **Token legacy, pas de token projeté.** Un token `TokenRequest` expire silencieusement et
>   fait tomber le cluster hors du hub sans alerte. Le type `kubernetes.io/service-account-token`
>   est délibéré.
> - **`ignoreDifferences` sur `/data` du Secret** (+ `RespectIgnoreDifferences=true`) : le token
>   controller écrit dans ce champ, sinon `OutOfSync` permanent.
> - **Poule et œuf.** Ce composant est le prérequis de sa propre réconciliation : il est posé une
>   fois à la main sur le cluster vierge (geste de bootstrap, cf. Opérations), puis adopté.
> - **Le token ne vit jamais en clair dans Git** : il n'existe que dans le cluster et dans le
>   `SealedSecret` de cluster scellé côté hub.

## Opérations

### Bootstrap — poser le SA et enregistrer le cluster dans le hub

Geste manuel unique, sur le cluster **arcanagos** (kubeconfig pointant dessus) :

```bash
kubectl apply -k bleu-arcanagos/infra/argocd-manager/manifests
kubectl -n kube-system get secret argocd-manager-token -o jsonpath='{.data.token}' | base64 -d ; echo
kubectl -n kube-system get secret argocd-manager-token -o jsonpath='{.data.ca\.crt}' ; echo
kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' ; echo
```

Le token controller remplit **trois** clés dans `argocd-manager-token` ; les voici mappées sur le
Secret de cluster du hub :

| Sortie | Champ côté hub | Encodage |
|---|---|---|
| `.data.token` | `config.bearerToken` | **à décoder** (`base64 -d`) : il part dans une chaîne JSON |
| `.data.ca\.crt` | `config.tlsClientConfig.caData` | **à copier tel quel** : `.data.` est déjà en base64, et `caData` attend du base64 de PEM |
| `.clusters[0].cluster.server` (kubeconfig) | `server` | texte brut |

> [!TIP]
> Si le Secret n'est pas encore rempli, le CA se récupère aussi ailleurs — même valeur :
> ```bash
> kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' ; echo
> kubectl -n kube-system get cm kube-root-ca.crt -o jsonpath='{.data.ca\.crt}' | base64 -w0 ; echo   # PEM → à encoder
> ```

Puis, côté **hub** : le cluster s'enregistre par un Secret ArgoCD, donc par un `SealedSecret`
committé — pas par `argocd cluster add`, qui est une écriture impérative. Renseigner le template
en clair (gitignoré) avec les trois valeurs ci-dessus :

```yaml
# bleu-kalecgos/infra/argocd/manifests/cluster-bleu-arcanagos.secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: cluster-bleu-arcanagos
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
stringData:
  name: bleu-arcanagos          # doit matcher destination.name des .app.yaml de ce cluster
  server: https://<apiserver>:6443                     # sortie de kubectl config view
  config: |
    {"bearerToken":"<token décodé>","tlsClientConfig":{"insecure":false,"caData":"<sortie de .data.ca\.crt, telle quelle>"}}
```

Sceller avec la clé du **hub**, committer, supprimer le clair
(cf. [runbook, étape 8](../../../doc/runbook-bootstrap.md)) :

```bash
kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
  < bleu-kalecgos/infra/argocd/manifests/cluster-bleu-arcanagos.secret.yaml \
  > bleu-kalecgos/infra/argocd/manifests/cluster-bleu-arcanagos.sealed.yaml
rm bleu-kalecgos/infra/argocd/manifests/cluster-bleu-arcanagos.secret.yaml
```

Référencer le `.sealed.yaml` dans `bleu-kalecgos/infra/argocd/manifests/kustomization.yaml`
(la ligne reste **commentée** tant que le fichier n'est pas scellé, sinon `kustomize build` casse).

### Debug

```bash
kubectl -n kube-system get sa argocd-manager
kubectl -n kube-system get secret argocd-manager-token -o jsonpath='{.type}' ; echo
kubectl auth can-i '*' '*' --all-namespaces \
  --as system:serviceaccount:kube-system:argocd-manager      # → yes
```

Côté hub, le cluster doit apparaître dans la liste et répondre :

```bash
kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=cluster
argocd cluster list                                          # bleu-arcanagos en Successful
```

### Révoquer / faire tourner le token

Supprimer le Secret dans le cluster : le token controller en régénère un immédiatement (le
manifeste, lui, est réconcilié par ArgoCD). L'ancien token est invalidé — il faut donc
**resceller** le Secret de cluster du hub avec la nouvelle valeur, sinon le hub perd l'accès.

```bash
kubectl -n kube-system delete secret argocd-manager-token
```
