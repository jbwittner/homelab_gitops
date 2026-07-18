# sealed-secrets

## Rôle

Contrôleur [Bitnami sealed-secrets](https://github.com/bitnami/sealed-secrets) : déchiffre dans
le cluster les `SealedSecret` committés dans Git. Seul canal autorisé pour les secrets —
règle : [doc/regles-gitops.md](../../../doc/regles-gitops.md).

## Fichiers

- `sealed-secrets.app.yaml` — Application (archétype (d) : Helm sans values).
  Contrôleur + namespace : `sealed-secrets`.

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
> <dossier-du-composant>/manifests/wildcard-kalecgos-lan-tls.sealed.yaml
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
