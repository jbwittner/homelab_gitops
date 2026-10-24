# OpenBao (malygos)

| Fichier | Rôle |
|---|---|
| `clusters/bleu-malygos/openbao/openbao.app.yaml` | `openbao-malygos`, namespace `openbao` |
| `clusters/bleu-malygos/openbao/values.yaml` | raft 1 réplica, PVC 10 Gi `openebs-lvm`, UI, pas d'injector, pas de PDB |

HTTP dans le cluster (`http://openbao.openbao:8200`). TLS au Gateway plus tard (`https://bao.lan.wittner.tech`).

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

UI (en attendant la Gateway) :

```sh
kubectl --context admin@bleu-malygos -n openbao port-forward svc/openbao-ui 8200:8200
```

`http://localhost:8200`, méthode Token.

## Configurer

Structure en Terraform : `homelab_terraform/openbao/bleu-malygos` (README du module : premier apply avec le token root, création de l'admin userpass, révocation du root).

## Sauvegarder (snapshot raft)

```sh
kubectl --context admin@bleu-malygos -n openbao exec -it openbao-0 -- \
  sh -c 'bao login -method=userpass username=jbwittner && bao operator raft snapshot save /tmp/openbao.snap'
kubectl --context admin@bleu-malygos -n openbao cp openbao-0:/tmp/openbao.snap ~/openbao-$(date +%F).snap
kubectl --context admin@bleu-malygos -n openbao exec openbao-0 -- rm /tmp/openbao.snap
```

Snapshot chiffré, mais inutilisable sans la clé d'unseal : les ranger ensemble hors dépôt.
