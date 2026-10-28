# OpenBao (malygos)

| Fichier | Rôle |
|---|---|
| `clusters/bleu-malygos/openbao/openbao.app.yaml` | `openbao-malygos`, namespace `openbao` |
| `clusters/bleu-malygos/openbao/values.yaml` | raft 1 réplica, PVC 10 Gi `openebs-lvm`, UI, pas d'injector, pas de PDB |

HTTP dans le cluster (`http://openbao.openbao:8200`). TLS au Gateway (`https://openbao.lan.wittner.tech`).

Tant qu'OpenBao est scellé, `openbao-0` n'est pas prêt : `openbao-malygos` reste `Progressing`.

## Initialiser (une fois)

```sh
kubectl --context admin@bleu-malygos -n openbao exec openbao-0 -- \
  bao operator init -key-shares=1 -key-threshold=1
```

Ranger **Unseal Key 1** et **Initial Root Token** dans le gestionnaire de mots de passe. Jamais dans le dépôt ni dans un fichier.

## Desceller (après l'init et à chaque redémarrage de malygos ou du pod)

```sh
kubectl --context admin@bleu-malygos -n openbao exec -it openbao-0 -- bao operator unseal   # clé demandée, non affichée
```

## Vérifier

```sh
kubectl --context admin@bleu-malygos -n openbao exec openbao-0 -- bao status   # Sealed false, HA Mode active
kubectl --context admin@bleu-malygos -n argocd get application openbao-malygos  # Synced / Healthy
```

UI : `https://openbao.lan.wittner.tech` ([exposition](exposition.md)), méthode OIDC (Authelia), Username `admin` en secours. CLI : `export BAO_ADDR=https://openbao.lan.wittner.tech`, puis `bao login -method=oidc`.

## Configurer

Structure en Terraform : `homelab_terraform/openbao/bleu-malygos` (README du module : premier apply avec le token root, création de l'admin userpass, révocation du root).

## Sauvegarder (snapshot raft)

Automatique chaque nuit par Velero ([sauvegardes.md](sauvegardes.md)). À la main :

```sh
export BAO_ADDR=https://openbao.lan.wittner.tech
bao login -method=oidc
bao operator raft snapshot save ~/openbao-$(date +%F).snap
```

Snapshot chiffré, mais inutilisable sans la clé d'unseal : les ranger ensemble hors dépôt.
