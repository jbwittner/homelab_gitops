# sealed-secrets

## Rôle

Contrôleur [Bitnami sealed-secrets](https://github.com/bitnami/sealed-secrets) : déchiffre dans
le cluster les `SealedSecret` committés dans Git. C'est l'un des **deux** canaux de secrets du
repo, aux côtés d'[openbao](../openbao/README.md) + [external-secrets](../external-secrets/README.md) —
critère de choix : [doc/regles-gitops.md](../../../doc/regles-gitops.md). Il porte les **deux**
secrets situés en amont du coffre dans le graphe de bootstrap : le token DNS de
`cert-manager-config` et le Secret de cluster du spoke. Wave **-8** : le contrôleur précède tout
SealedSecret consommé plus tard.

## Fichiers

- `sealed-secrets.app.yaml` — Application (archétype (d) : Helm sans values).
  Contrôleur et namespace : `sealed-secrets`.

## Contraintes

> [!CAUTION]
> **La clé privée du contrôleur est le seul état non reconstructible du cluster.** Un contrôleur
> qui démarre sans clé restaurée en génère une **neuve** : tous les `SealedSecret` du repo
> deviennent indéchiffrables et chaque credential amont est à re-provisionner. En reconstruction,
> la clé se restaure **avant** le premier démarrage du contrôleur — étape 3 du
> [runbook](../../../doc/runbook-bootstrap.md).

## Opérations

Commandes **depuis la racine du repo**.

### Sceller un Secret

```bash
# 1. Récupérer le cert public du contrôleur (une fois ; pub-cert.pem est gitignoré)
kubeseal --fetch-cert \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets \
  > pub-cert.pem

# 2. Template en clair (gitignoré) → SealedSecret, dans le manifests/ du composant consommateur
kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
  < cluster/<partie>/<name>/manifests/<secret>.secret.yaml \
  > cluster/<partie>/<name>/manifests/<secret>.sealed.yaml

# 3. Supprimer le clair, référencer le .sealed.yaml dans le kustomization.yaml, committer
rm cluster/<partie>/<name>/manifests/<secret>.secret.yaml
```

Le `SealedSecret` est chiffré **pour un couple (nom, namespace)** donné : le déplacer d'un
namespace à l'autre le rend indéchiffrable, il faut le resceller.

### Backup / restauration de la clé

```bash
# Backup — contient la clé privée : coffre, JAMAIS dans Git (motif .gitignore déjà en place).
# Le suffixe du nom de fichier est le cluster : une clé par contrôleur, et restaurer celle d'un
# autre cluster rend tous les SealedSecret indéchiffrables.
kubectl get secret -n sealed-secrets \
  -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealed-secrets-key-bleu-kalecgos.yaml

# Restauration (AVANT le démarrage du contrôleur), puis restart
kubectl apply -f sealed-secrets-key-bleu-kalecgos.yaml
kubectl rollout restart deployment/sealed-secrets -n sealed-secrets

# Quelle clé sert à sceller ? La PLUS RÉCENTE. Les autres restent utilisées au déchiffrement.
kubectl get secrets -n sealed-secrets \
  -l sealedsecrets.bitnami.com/sealed-secrets-key --sort-by=.metadata.creationTimestamp
```

### Debug

```bash
kubectl get sealedsecrets -A
kubectl describe sealedsecret <name> -n <ns>     # events : « no key could decrypt secret » = mauvaise clé
kubectl logs -n sealed-secrets deploy/sealed-secrets
```
