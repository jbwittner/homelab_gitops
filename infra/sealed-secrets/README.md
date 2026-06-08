# Sealed Secrets

## Prérequis

```bash
brew install kubeseal
```

## 1. Récupérer le certificat public (chiffrement offline)

Récupérer le cert du cluster et le sauvegarder localement pour pouvoir chiffrer sans accès direct au cluster :

```bash
kubeseal --fetch-cert \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets \
  > pub-cert.pem
```

Chiffrer ensuite offline :

```bash
kubeseal --cert pub-cert.pem --format yaml < secret.yaml > sealed-secret.yaml
```

## 2. Chiffrer un secret (accès cluster direct)

À partir d'un fichier `secret.yaml` existant :

```bash
kubeseal \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets \
  --format yaml < secret.yaml > sealed-secret.yaml
```

Chiffrer une valeur brute, scope **namespace** (ne peut être déchiffré que dans le namespace cible) :

```bash
echo -n "ma-valeur-secrete" | kubeseal --raw \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets \
  --namespace=<target-namespace> \
  --name=<secret-name> \
  --from-file=/dev/stdin
```

Chiffrer une valeur brute, scope **cluster-wide** (déchiffrable dans n'importe quel namespace) :

```bash
echo -n "ma-valeur-secrete" | kubeseal --raw \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets \
  --scope=cluster-wide \
  --from-file=/dev/stdin
```

## 3. Sauvegarder les clés de déchiffrement

> **Important** — ce fichier contient les clés privées. Ne jamais committer en clair dans Git. Chiffrer avec age/gpg ou stocker dans un coffre (Bitwarden, etc.).

```bash
kubectl get secret -n sealed-secrets \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealed-secrets-keys-backup.yaml
```

## 4. Restaurer les clés (après rebuild cluster)

Ré-injecter les clés **avant** que le controller ne démarre, puis le redémarrer :

```bash
kubectl apply -f sealed-secrets-keys-backup.yaml

kubectl rollout restart deployment/sealed-secrets -n sealed-secrets
```

## 5. Rotation de clés

Les nouvelles clés sont générées automatiquement tous les 30 jours. Les anciens SealedSecrets restent déchiffrables car les vieilles clés sont conservées.

Forcer une rotation manuelle :

```bash
kubectl label secret -n sealed-secrets \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  sealedsecrets.bitnami.com/sealed-secrets-key=compromised
```

## 6. Vérifier / Déboguer

```bash
# Lister les SealedSecrets et leur état
kubectl get sealedsecrets -A

# Voir les événements sur un SealedSecret qui ne se déchiffre pas
kubectl describe sealedsecret <name> -n <namespace>

# Logs du controller
kubectl logs -n sealed-secrets deploy/sealed-secrets
```
