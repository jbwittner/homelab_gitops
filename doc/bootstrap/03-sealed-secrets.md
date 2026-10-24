# 3. Sealed Secrets (malygos)

Controller dans `kube-system`. Sert uniquement au boot (GitHub App ArgoCD, secret de cluster kalecgos).

## Installer

Version lue dans `sealed-secrets.app.yaml` (tenue à jour par Renovate).

```sh
V=$(yq '.spec.sources[] | select(.chart == "sealed-secrets") | .targetRevision' clusters/bleu-malygos/sealed-secrets/sealed-secrets.app.yaml)

helm --kube-context admin@bleu-malygos upgrade --install sealed-secrets sealed-secrets \
  --repo https://bitnami.github.io/sealed-secrets --version $V -n kube-system \
  -f clusters/bleu-malygos/sealed-secrets/values.yaml

kubectl --context admin@bleu-malygos -n kube-system rollout status deploy/sealed-secrets-controller
```

## Sauvegarder la clé

Rotation désactivée (`keyrenewperiod: "0"`) : une sauvegarde suffit.

```sh
kubectl --context admin@bleu-malygos -n kube-system get secret \
  -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealed-secrets-key-backup.yaml
```

Ranger le fichier hors dépôt (gestionnaire de mots de passe), puis le supprimer. `.gitignore` l'exclut.

## Restaurer la clé (cluster réinstallé)

```sh
kubectl --context admin@bleu-malygos apply -f sealed-secrets-key-backup.yaml
kubectl --context admin@bleu-malygos -n kube-system rollout restart deploy/sealed-secrets-controller
```

## Sceller un secret

Copier `x.secret.example.yaml` en `x.secret.yaml`, remplir les valeurs (`stringData`), puis :

```sh
kubeseal --context admin@bleu-malygos -o yaml < x.secret.yaml > x.sealed.yaml
```

`x.secret.yaml` n'est jamais commité (`.gitignore`).

## Vérifier

```sh
kubectl --context admin@bleu-malygos -n kube-system get deploy sealed-secrets-controller   # READY 1/1
kubectl --context admin@bleu-malygos -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key   # 1 clé
```
