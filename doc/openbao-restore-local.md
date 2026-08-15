# Remonter un OpenBao en local depuis une sauvegarde

## Rôle

Vérifier qu'une sauvegarde du coffre est **réellement restaurable**, en la remontant dans un
OpenBao jetable sur le poste, hors cluster. Le contenu d'OpenBao est la seule chose du homelab
absente de Git : c'est la seule sauvegarde dont l'échec ne se verrait nulle part ailleurs.

Les snapshots sont produits par le CronJob `snapshotAgent` de
[`cluster/infra/openbao`](../cluster/infra/openbao/README.md) (tous les jours à 03:00, rétention
14 jours) et poussés dans le bucket GCS `homelab-openbao-snapshots-6d84c670`. **La présence d'un
objet dans le bucket ne prouve rien** : ni que l'archive est complète, ni que la barrière de
chiffrement est descellable, ni que la configuration posée par le repo Terraform y est. Seul un
restore le prouve.

⚠️ **Ne jamais tester un restore sur `openbao-0`.** `bao operator raft snapshot restore` écrase
l'intégralité du raft. Le test se fait sur une instance jetable, et rien de cette procédure ne
touche le cluster.

## Le script fait tout ça

Cette page décrit la manipulation à la main, pour la comprendre et pour la conduire quand quelque
chose sort du cadre. Au quotidien, tout est automatisé par
[`cluster/infra/openbao/openbao-script.sh`](../cluster/infra/openbao/openbao-script.sh) :

```bash
cluster/infra/openbao/openbao-script.sh verify latest            # étapes 1 à 5, aucune clé requise
cluster/infra/openbao/openbao-script.sh verify oldest --unseal   # + étapes 6 et 7
```

Le script encapsule les pièges listés plus bas et compare tout seul la configuration de seal
obtenue à celle de la prod. Lire la suite si l'on veut savoir ce qu'il fait, ou s'en passer.

## Prérequis

| Quoi | Pourquoi |
|---|---|
| `docker` | porte l'instance jetable |
| `gsutil` authentifié sur le projet GCP | lire le bucket de snapshots |
| `jq` | lire les sorties JSON |
| **3 des 5 parts de descellement de PROD** | le restore ramène le keyring du coffre source (cf. §Étape 6) — requis seulement pour le test complet |
| **Le token root de PROD** | lire le contenu après descellement — requis seulement pour le test complet |

Les parts et le token root vivent **hors cluster**, au coffre physique (cf.
[`cluster/infra/openbao/README.md`](../cluster/infra/openbao/README.md) §Contraintes). Sans eux,
la procédure s'arrête à l'étape 5 — ce qui reste un test utile, voir §Deux niveaux de test.

## Deux niveaux de test

La procédure se lit en deux temps, et le premier ne demande **aucun secret** :

1. **Étapes 1 à 5 — sans les clés.** Contrôle structurel de l'archive, puis restore dans une
   instance jetable. La preuve est que la configuration de seal de l'instance passe de celle
   qu'on vient de créer (`1 / 1`) à celle de la prod (`5 / 3`) : le keyring du snapshot a été
   chargé, donc `state.bin` est intègre et lisible par OpenBao. C'est automatisable, et c'est ce
   qu'il faut faire souvent.
2. **Étapes 6 à 7 — avec les clés.** Descellement effectif et lecture du contenu. Seul test qui
   prouve que les parts en ta possession ouvrent bien *cette* sauvegarde, et que les sept chemins
   KV plus la configuration Terraform sont dedans. À faire à la main, une ou deux fois par an.

## Sécurité

- Le snapshot contient **tout le coffre, chiffré**. Il ne vaut rien sans les parts de
  descellement, mais il se traite comme un secret : hors du répertoire du repo, supprimé après.
  Le `.gitignore` filtre `*.secret.yaml`, **pas** `*.snapshot` — un snapshot déposé dans le repo
  serait committé sans un bruit.
- Une fois l'étape 6 franchie, l'instance locale contient **tous les secrets du homelab en
  clair**, servis sur un port de la machine. Ne pas la laisser tourner, ne pas publier le port
  au-delà de `127.0.0.1`.
- L'étape 8 (nettoyage) fait partie de la procédure, pas des options : le volume Docker garde
  l'état restauré après l'arrêt du conteneur.

## Procédure

### 1. Choisir et récupérer un snapshot

```bash
mkdir -p ~/bao-drill/snap && cd ~/bao-drill
gsutil ls -l gs://homelab-openbao-snapshots-6d84c670/
gsutil cp gs://homelab-openbao-snapshots-6d84c670/bao_AAAA-MM-JJ-HHMM.snapshot snap/
```

Tester de préférence le **plus ancien** snapshot encore en rétention, pas celui de la nuit : c'est
lui qui répond à la vraie question, « jusqu'où puis-je remonter ». Ordre de grandeur attendu :
quelques dizaines de kilo-octets — ce sont des KV chiffrés, pas des données applicatives. Un objet
de quelques centaines d'octets est un échec d'upload.

### 2. Contrôle structurel

```bash
tar tzvf snap/bao_AAAA-MM-JJ-HHMM.snapshot
```

Quatre entrées attendues :

| Fichier | Contenu |
|---|---|
| `meta.json` | version, `Index` / `Term` raft, configuration des pairs, taille de `state.bin` |
| `state.bin` | la base bolt du coffre, chiffrée |
| `SHA256SUMS` | empreintes de `meta.json` et `state.bin` |
| `SHA256SUMS.sealed` | l'équivalent scellé, vérifié par OpenBao au restore |

```bash
tar xzOf snap/bao_AAAA-MM-JJ-HHMM.snapshot meta.json | jq .
mkdir -p x && tar xzf snap/bao_AAAA-MM-JJ-HHMM.snapshot -C x && (cd x && shasum -a 256 -c SHA256SUMS)
```

`meta.json` doit montrer un `Index` qui progresse d'un snapshot à l'autre — un `Index` figé sur
plusieurs jours signale un coffre qui n'écrit plus, pas une sauvegarde saine. Le `Servers` liste
les pairs raft au moment du snapshot (`openbao-0` seul aujourd'hui).

Si `tar` échoue ou si `shasum -c` sort autre chose que `OK`, l'archive est morte : inutile d'aller
plus loin, remonter au snapshot précédent et regarder les logs du CronJob
(`kubectl -n openbao logs job/openbao-snapshot-<id>`).

### 3. Lancer l'instance jetable

Le mode `-dev` **ne convient pas** : il stocke en mémoire, et `snapshot restore` exige le backend
raft.

```bash
cat > config.hcl <<'EOF'
api_addr     = "http://127.0.0.1:8200"
cluster_addr = "http://127.0.0.1:8201"

listener "tcp" {
  address     = "[::]:8200"
  tls_disable = 1
}

storage "raft" {
  path    = "/openbao/file"
  node_id = "restore-test"
}
EOF

docker volume create bao-restore-data
docker run -d --name bao-restore-test -p 127.0.0.1:8210:8200 \
  -v "$PWD/config.hcl:/etc/openbao/config.hcl:ro" \
  -v "$PWD/snap:/snap:ro" \
  -v bao-restore-data:/openbao/file \
  quay.io/openbao/openbao:2.6.1 server -config=/etc/openbao/config.hcl

docker logs bao-restore-test   # « OpenBao server started! »
```

Trois détails qui coûtent chacun un aller-retour si on les découvre en direct :

- **Le fichier de config ne va pas dans `/openbao/config`.** L'entrypoint de l'image lit déjà ce
  répertoire ; y monter un `.hcl` donne `ignoring duplicate configuration found in directory` et
  la config est ignorée. Le monter ailleurs (`/etc/openbao/`) et le passer en `-config=`.
- **Le chemin raft est `/openbao/file`, pas `/openbao/data`.** `/openbao/data` n'existe pas dans
  l'image (`failed to open bolt file: no such file or directory`), et le créer par un volume le
  fait naître `root` alors que le processus tourne en `uid 100` (`permission denied`).
  `/openbao/file` existe et appartient déjà à `openbao`.
- **Pas de `disable_mlock`.** Le champ n'existe plus en 2.6.1 (`unknown or unsupported field
  disable_mlock`) et l'absence de la capability `IPC_LOCK` ne gêne pas. C'est l'inverse du
  cluster, où le README d'openbao mentionne `disable_mlock` comme correctif — cette note vaut
  pour les versions antérieures.

Garder la même version d'image que le cluster :

```bash
kubectl -n openbao get sts openbao -o jsonpath='{.spec.template.spec.containers[0].image}'
```

### 4. Initialiser l'instance jetable

On ne restaure pas dans un coffre non initialisé. Les clés produites ici sont **jetables** : le
restore les détruit à l'étape suivante. Une seule part suffit.

```bash
alias baot='docker exec -e BAO_ADDR=http://127.0.0.1:8200 bao-restore-test bao'

baot operator init -key-shares=1 -key-threshold=1 -format=json > init.json
baot operator unseal "$(jq -r '.unseal_keys_b64[0]' init.json)"
baot status     # Sealed=false, Total Shares 1, Threshold 1  ← à retenir pour l'étape 5
```

### 5. Restaurer

```bash
docker exec -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN="$(jq -r .root_token init.json)" \
  bao-restore-test bao operator raft snapshot restore -force /snap/bao_AAAA-MM-JJ-HHMM.snapshot
```

`-force` est **obligatoire** : sans lui, OpenBao refuse un snapshot dont la configuration de seal
diffère de la sienne — ce qui est toujours le cas ici, puisqu'on vient d'initialiser l'instance
avec d'autres clés.

⚠️ La commande affiche `Error properly closing policy file: close … file already closed`.
**C'est cosmétique, le restore a réussi.** Ne pas s'y fier dans un sens ni dans l'autre : la
preuve est le `status`.

⚠️ **Redémarrer le conteneur AVANT de lire le status. C'est le piège le moins visible de toute la
procédure.** Le processus garde en mémoire la configuration de seal avec laquelle il a démarré :
juste après un restore réussi, `bao status` continue d'annoncer `1 / 1`, alors que le stockage
porte déjà les `5 / 3` du coffre source. On conclut que le restore n'a rien fait, alors qu'il a
parfaitement fonctionné — les logs, eux, l'écrivent noir sur blanc :

```bash
docker logs bao-restore-test 2>&1 | grep -E 'restored user snapshot|marked as sealed'
#   storage.raft: restored user snapshot: index=919
#   core: failed to perform key upgrades, sealing: … cipher: message authentication failed
#   core: marked as sealed
```

Ce `failed to perform key upgrades, sealing` n'est pas une erreur : c'est le coffre qui constate
que le keyring a changé sous lui et qui se rescelle, exactement comme prévu.

```bash
docker restart bao-restore-test && sleep 5
baot status
```

C'est **le point de contrôle de la procédure**, et il ne demande aucun secret :

| Champ | Avant restore | Après restore | Lecture |
|---|---|---|---|
| `Total Shares` | `1` | **`5`** | la configuration de seal vient du snapshot |
| `Threshold` | `1` | **`3`** | idem |
| `Sealed` | `false` | **`true`** | attendu : le keyring a changé sous le coffre |

`5 / 3` = les valeurs de la prod (`kubectl -n openbao exec openbao-0 -- bao status`). Le snapshot
a donc été ouvert, vérifié et chargé : `state.bin` est intègre. Si les valeurs restent à `1 / 1`,
le restore n'a rien fait, quoi qu'ait affiché la commande.

**Sans les clés de prod, le test s'arrête ici** — et il a déjà écarté tous les modes d'échec
silencieux du chemin de sauvegarde (upload tronqué, archive corrompue, snapshot vide).

### 6. Desceller avec les parts de PROD

```bash
baot operator unseal <part-PROD-1>
baot operator unseal <part-PROD-2>
baot operator unseal <part-PROD-3>
baot status     # Sealed=false
```

Ni la part jetable de l'étape 4, ni son token root ne fonctionnent plus : le restore a remplacé
la barrière par celle du coffre source. C'est ce qui rend ce test concluant — il vérifie que
**les parts que tu détiens ouvrent cette sauvegarde-là**.

Si le descellement échoue ici, la sauvegarde est inutilisable et le problème n'est pas dans le
fichier : les parts en ta possession ne correspondent plus au coffre. Le contenu du snapshot est
alors définitivement illisible, et c'est le scénario le plus grave que cette procédure sache
détecter.

### 7. Vérifier le contenu

```bash
baot login <root-token-PROD>

baot secrets list                 # kv/ en v2
baot auth list                    # kubernetes-bleu-kalecgos/ et oidc/
baot policy list
baot read auth/kubernetes-bleu-kalecgos/role/external-secrets
baot list identity/group/name     # app-openbao-admin
```

Puis les chemins servis aux applications. **Ne pas les recopier depuis le README** : sa table
« Contenu du coffre » a divergé. Les dériver des `ExternalSecret` du cluster, qui sont le
consommateur réel et ne peuvent pas mentir :

```bash
kubectl get externalsecrets -A -o json | jq -r '
  [ .items[]
    | select(.spec.secretStoreRef.name == "openbao")
    | .spec.data[]?
    | "\(.remoteRef.key)\t\(.remoteRef.property // "")" ]
  | unique | .[]' | while IFS=$'\t' read -r key prop; do
    baot kv get -mount=kv -format=json "$key" \
      | jq -e --arg p "$prop" '.data.data | has($p)' >/dev/null \
      && echo "ok  $key → $prop" || echo "KO  $key → $prop"
  done
```

État constaté au 15 août 2026 — six chemins, huit clés :

| Chemin KV | Clés | Consommateur |
|---|---|---|
| `homelab/argocd` | `grafana-api-key`, `oidc-client-secret` | argocd |
| `homelab/authentik/secrets` | `secret-key` | authentik |
| `homelab/cert-manager` | `cloudflare-api-token` | cert-manager-config |
| `homelab/grafana/admin` | `admin-user`, `admin-password` | kube-prometheus-stack |
| `homelab/grafana/oidc` | `client-secret` | kube-prometheus-stack |
| `homelab/renovate` | `github_token` | renovate |

Vérifier explicitement le volet **auth / policies / roles**, pas seulement le KV : cette
configuration est posée par le repo Terraform, elle vit dans le raft, et elle revient donc avec le
snapshot. C'est la partie qu'on oublie de contrôler et sans laquelle les sept `ExternalSecret`
repartiraient en `permission denied` après une restauration réelle.

### 8. Nettoyer

Non optionnel : le volume survit au conteneur, et il contient l'état restauré.

```bash
docker rm -f bao-restore-test
docker volume rm bao-restore-data
cd ~ && rm -rf ~/bao-drill
```

## Ce que cette procédure ne couvre pas

- **La restauration dans le cluster.** Elle valide la donnée, pas le chemin de retour (PVC
  openebs, chart, RBAC, descellement pod par pod). Pour ça, il faut une répétition sur une
  seconde instance en cluster, éphémère.
- **La consommation par ESO.** Repointer le `ClusterSecretStore` sur une instance de test n'est
  pas une manipulation à faire sur un cluster vivant.
- **La surveillance du CronJob lui-même.** Aucune alerte ne remonte aujourd'hui un
  `openbao-snapshot` en échec — le ServiceMonitor de
  [openbao-monitoring](../cluster/infra/openbao-monitoring/README.md) ne porte que sur le serveur.
  Un snapshot qui cesse d'être produit ne se voit qu'en regardant le bucket.

## Table des symptômes

| Symptôme | Cause | Correctif |
|---|---|---|
| `ignoring duplicate configuration found in directory` | config montée dans `/openbao/config` | la monter ailleurs, `-config=<chemin>` |
| `failed to open bolt file: no such file or directory` | `path` raft inexistant dans l'image | `path = "/openbao/file"` |
| `failed to open bolt file: permission denied` | volume créé `root`, processus en `uid 100` | monter sur `/openbao/file`, déjà possédé par `openbao` |
| `unknown or unsupported field disable_mlock` | champ retiré en 2.6.x | l'enlever de `config.hcl` |
| `Error properly closing policy file: … already closed` | message cosmétique du restore | ignorer, vérifier `bao status` |
| Restore refusé sans message clair | seal config différente | ajouter `-force` |
| `Total Shares` reste à `1` après restore | config de seal lue en mémoire, pas au stockage | **`docker restart`**, puis relire — cause n°1 des faux négatifs |
| `Total Shares` reste à `1` même après redémarrage | le restore n'a réellement rien fait | vérifier le chemin du snapshot dans le conteneur, et `docker logs` (`restored user snapshot`) |
| `failed to perform key upgrades, sealing` dans les logs | le keyring a changé sous le coffre | attendu après un restore réussi, pas une erreur |
| Descellement refusé avec les parts de prod | parts et sauvegarde désaccordées | sauvegarde inexploitable — incident, pas un problème de procédure |
