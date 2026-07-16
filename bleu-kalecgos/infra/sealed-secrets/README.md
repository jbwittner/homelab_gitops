# Sealed Secrets — bleu-kalecgos

Contrôleur [Bitnami sealed-secrets](https://github.com/bitnami/sealed-secrets) déployé via Helm
(`sealed-secrets.app.yaml`, wave 0). Ce dossier ne contient **aucun Secret en clair** : tout secret
du cluster est un `SealedSecret` chiffré, committé dans Git, déchiffré par le contrôleur.

- **Namespace contrôleur** : `sealed-secrets`
- **Nom contrôleur** : `sealed-secrets`
- **Chart** : `sealed-secrets` 2.19.1 (app v0.38.4)

## Règle GitOps

> Aucune donnée (Secret, ConfigMap sensible, cert TLS) ne doit être poussée au cluster hors GitOps.
> Pas de `kubectl create secret` impératif. Tout passe par un `SealedSecret` dans Git.

## Sceller un Secret

```bash
# 1. Récupérer le cert public (une fois)
kubeseal --fetch-cert \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets \
  > pub-cert.pem

# 2. Depuis un Secret K8s (fichier secret.yaml, jamais committé) → SealedSecret
kubeseal --cert pub-cert.pem --format yaml < secret.yaml > sealed-secret.yaml

# 3. Committer UNIQUEMENT sealed-secret.yaml
```

Exemple cert TLS wildcard :

```bash
kubectl create secret tls wildcard-kalecgos-lan-tls \
  --cert=tls.crt --key=tls.key \
  --namespace=gateway --dry-run=client -o yaml \
| kubeseal --cert pub-cert.pem --format yaml \
> ../gateway/wildcard-kalecgos-lan-tls.sealed.yaml
```

## Backup / restauration de la clé

> La clé privée du contrôleur est dans le cluster. La perdre = tous les SealedSecrets indéchiffrables.

```bash
# Backup (contient la clé privée — chiffrer/coffre, JAMAIS en clair dans Git)
kubectl get secret -n sealed-secrets \
  -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > keys-backup.yaml

# Restauration (AVANT démarrage contrôleur), puis restart
kubectl apply -f keys-backup.yaml
kubectl rollout restart deployment/sealed-secrets -n sealed-secrets
```

## Debug

```bash
kubectl get sealedsecrets -A
kubectl describe sealedsecret <name> -n <ns>
kubectl logs -n sealed-secrets deploy/sealed-secrets
```
