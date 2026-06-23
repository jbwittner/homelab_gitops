# examples — neltharion

Dossier **purement pédagogique** : des exemples de manifestes pour montrer les conventions
du cluster. **Aucune ressource n'est déployée d'ici** — il n'y a pas de `*.app.yaml` ni de
`*.bootstrap.yaml`, donc rien n'est capté par les globs de l'app-of-apps (cf.
[`../README.md`](../README.md)).

## Secrets (SealedSecrets)

Le flux complet, du secret en clair au manifeste committé :

| Fichier | Rôle | Committé ? |
|---------|------|-----------|
| [`secret.example.yaml`](secret.example.yaml) | Placeholder **en clair** (`Secret`), entrée de `kubeseal`. En vrai : `<name>.secret.yaml`, **gitignored** (`*.secret.yaml`). | ❌ (le vrai est gitignored) |
| [`sealed-secret.example.yaml`](sealed-secret.example.yaml) | **Sortie** de `kubeseal` (`SealedSecret`), déchiffrée par le contrôleur dans le cluster. En vrai : `<name>.sealed-secret.yaml`, listé dans le `kustomization.yaml`. | ✅ |

> ⚠️ Les `encryptedData` de [`sealed-secret.example.yaml`](sealed-secret.example.yaml) sont
> **factices**. Un vrai SealedSecret n'est déchiffrable que par le contrôleur du cluster qui
> l'a scellé (**SealedSecrets = par-cluster**).

### Procédure type

```bash
# 1. Copier l'exemple à côté du composant, sous son vrai nom (gitignored) :
cp neltharion/examples/secret.example.yaml \
   neltharion/<infra|apps>/<name>/<secret-name>.secret.yaml
# 2. Éditer : metadata.name / namespace + valeurs réelles sous stringData.

# 3. Sceller directement contre le contrôleur (pas de cert local) :
kubeseal --controller-name=sealed-secrets --controller-namespace=sealed-secrets --format yaml \
  < neltharion/<infra|apps>/<name>/<secret-name>.secret.yaml \
  > neltharion/<infra|apps>/<name>/<secret-name>.sealed-secret.yaml

# 4. Committer UNIQUEMENT le sealed-secret (le .secret.yaml en clair reste gitignored) :
git add neltharion/<infra|apps>/<name>/<secret-name>.sealed-secret.yaml
```

Procédures kubeseal détaillées (offline via cert, `--raw`, backup/restore de la clé) :
[`../infra/sealed-secrets/README.md`](../infra/sealed-secrets/README.md).

Exemple concret en place : [`../apps/renovate/`](../apps/renovate/) (secret
`renovate-github-env`).
