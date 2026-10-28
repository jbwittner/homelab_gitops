# 2. Cilium

CNI + pool LB + annonces L2.

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

# pool LB + annonces L2 (CRDs créées par Cilium au démarrage)
kubectl --context $CTX apply --server-side -f clusters/$C/cilium/manifests
```

Cilium déjà installé avant l'étape 1 : relancer le `helm upgrade` (crée la GatewayClass) puis `kubectl --context $CTX -n kube-system rollout restart deploy/cilium-operator`.

## Vérifier

```sh
kubectl --context $CTX get gatewayclass cilium        # ACCEPTED=True
kubectl --context $CTX get ciliumloadbalancerippool   # DISABLED=false
```

Annonces L2 (Service jetable) :

```sh
kubectl --context $CTX create deploy l2-test --image=nginx --port=80
kubectl --context $CTX expose deploy l2-test --type=LoadBalancer --port=80
kubectl --context $CTX get svc l2-test                       # EXTERNAL-IP dans la plage
curl -s -o /dev/null -w '%{http_code}\n' http://<EXTERNAL-IP>   # 200
kubectl --context $CTX delete svc,deploy l2-test
```

Le label Talos `exclude-from-external-load-balancers` des control-planes ne bloque pas les annonces L2 (vérifié le 2026-10-24).
