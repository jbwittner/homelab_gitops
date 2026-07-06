# Sealed Secrets

> Ce dossier ne contient **aucun manifeste** : le contrôleur sealed-secrets est déployé via
> la chart Helm référencée dans `onyxia/infra/sealed-secrets/sealed-secrets.app.yaml` (wave 0).
> Ce README couvre uniquement les procédures opérationnelles (kubeseal, backup/restore de clé).

> **Par-cluster.** La clé de ce contrôleur est propre à onyxia. Tout SealedSecret d'onyxia doit
> être scellé contre **cette** clé — ne jamais réutiliser un SealedSecret de neltharion.

## Prérequis

```bash
brew install kubeseal
```

## 1. Récupérer le certificat public (chiffrement offline)

```bash
kubeseal --fetch-cert \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets \
  > pub-cert.pem

kubeseal --cert pub-cert.pem --format yaml < secret.yaml > sealed-secret.yaml
```

## 2. Chiffrer un secret (accès cluster direct — recommandé)

```bash
kubeseal \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets \
  --format yaml < secret.yaml > sealed-secret.yaml
```

## 3. Sauvegarder les clés de déchiffrement

> **Important** — clés privées. Ne jamais committer en clair. Chiffrer (age/gpg) ou coffre.

```bash
kubectl get secret -n sealed-secrets \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealed-secrets-keys-backup.yaml
```

## 4. Restaurer les clés (après rebuild cluster)

```bash
kubectl apply -f sealed-secrets-keys-backup.yaml
kubectl rollout restart deployment/sealed-secrets -n sealed-secrets
```

## 5. Vérifier / Déboguer

```bash
kubectl get sealedsecrets -A
kubectl describe sealedsecret <name> -n <namespace>
kubectl logs -n sealed-secrets deploy/sealed-secrets
```
