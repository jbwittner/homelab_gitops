# renovate

## Rôle

Mises à jour de dépendances automatisées via [Renovate](https://docs.renovatebot.com/) en mode
self-hosted. Un `CronJob` **quotidien** lance le bot sur les dépôts GitHub ciblés et ouvre des PR
de bump. Aucune exposition réseau (job batch, pas de service).

Le délai avant qu'un bump soit proposé ne vient **pas** de la cadence du cron mais de
`minimumReleaseAge` (7 jours) dans le `renovate.json` **à la racine du repo** : une release doit
avoir 7 jours révolus avant qu'une branche ou une PR soit créée.

## Fichiers

- `renovate.app.yaml` — Application (archétype (c), path → `manifests/`)
- `manifests/cron-job.yaml` — `CronJob` quotidien, `concurrencyPolicy: Forbid`,
  `restartPolicy: Never`. Dépôts ciblés en `args`, configuration du bot via `env` + `envFrom`
  (secret `renovate-env`)
- `manifests/namespace.yaml` — ns `renovate` (`sync-wave: -1`)
- `manifests/renovate-env.sealed.yaml` — `SealedSecret` `renovate-env` (PAT GitHub), déchiffré par
  [sealed-secrets](../../infra/sealed-secrets/README.md). **Absent du repo tant que le scellement
  n'a pas été fait** — cf. §Câblage du secret
- `manifests/renovate-env.secret.example.yaml` — template de scellement, versionné et sans valeur.
  Jamais dans `kustomization.yaml`
- `manifests/renovate.externalsecret.yaml` — ancien canal : `ExternalSecret` servi par
  [openbao](../../infra/openbao/README.md). Encore actif tant que le `SealedSecret` n'existe pas
- `manifests/kustomization.yaml` — assemblage

## Contraintes

- La politique de mise à jour (cooldown, automerge, managers, chemins ignorés) vit dans
  `renovate.json` **à la racine**, pas ici. Notamment : `internalChecksFilter: strict` est
  load-bearing — sans lui, `ignoreTests: true` rendrait l'automerge immédiat malgré le cooldown.
- **Argo CD n'est jamais automergé** (`packageRules` de `renovate.json`) : il est self-managed,
  un bump raté casse le moteur GitOps lui-même.
- Cilium et les CRDs Gateway API sont proposés indépendamment alors qu'ils sont **couplés** :
  relire la compatibilité avant de merger (cf. [gateway-api](../../infra/gateway-api/README.md)).

## Opérations

### Câblage du secret

Canal : **sealed-secrets** (le `SealedSecret` porte la valeur chiffrée, pas un pointeur vers un
coffre). Le contrôleur est en wave `-8`, donc bien avant cette app.

Une seule entrée à fournir — le PAT GitHub — mais **deux clés** dans le Secret : Renovate attend le
même token sous `RENOVATE_TOKEN` (plateforme) et `RENOVATE_GITHUB_COM_TOKEN` (lookups de releases
sur github.com). Un `SealedSecret` chiffrant clé par clé, la valeur est saisie deux fois dans le
template.

```bash
# 1. Template en clair (gitignoré via *.secret.yaml)
cp cluster/app/renovate/manifests/renovate-env.secret.example.yaml \
   cluster/app/renovate/manifests/renovate-env.secret.yaml
# renseigner les deux REMPLACER avec le MÊME PAT

# 2. Sceller
kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
  < cluster/app/renovate/manifests/renovate-env.secret.yaml \
  > cluster/app/renovate/manifests/renovate-env.sealed.yaml

# 3. Supprimer le clair
rm cluster/app/renovate/manifests/renovate-env.secret.yaml
```

4. Dans `manifests/kustomization.yaml`, **échanger les deux lignes** — décommenter
   `renovate-env.sealed.yaml`, commenter `renovate.externalsecret.yaml` — puis committer le tout
   en un seul commit. Les deux visent le même Secret `renovate-env` et ne peuvent pas coexister.

> [!WARNING]
> Ne pas décommenter la ligne `renovate-env.sealed.yaml` avant que le fichier existe : un
> `resources:` pointant un fichier absent fait échouer le `kustomize build` entier et
> l'Application part en `ComparisonError`.

Le `SealedSecret` est chiffré pour le couple (`renovate-env`, `renovate`) : le renommer ou changer
son namespace le rend indéchiffrable.

**Rotation** : régénérer le PAT côté GitHub, puis refaire les étapes 1→3. Le fichier scellé est
remplacé en entier — il faut re-fournir les **deux** valeurs, un `SealedSecret` ne se relit pas.

#### Migration depuis openbao

L'ancien canal reste dans le repo (`renovate.externalsecret.yaml`, `deletionPolicy: Retain`).
Récupérer le PAT en place avant de le retirer :

```bash
kubectl -n renovate get secret renovate-env -o jsonpath='{.data.RENOVATE_TOKEN}' | base64 -d
# ou, côté coffre
kubectl -n openbao exec -ti openbao-0 -- bao kv get -field=github_token kv/homelab/renovate
```

Grâce à `deletionPolicy: Retain`, le prune de l'`ExternalSecret` par Argo CD **ne supprime pas** le
Secret : la bascule est sans coupure. Corollaire : un scellement raté ne se voit pas au prochain
run, le Secret orphelin continuant de servir. Vérifier explicitement que le Secret est bien devenu
propriété du `SealedSecret` :

```bash
kubectl -n renovate get sealedsecret renovate-env
kubectl -n renovate get secret renovate-env -o jsonpath='{.metadata.ownerReferences}'
```

L'entrée `kv/homelab/renovate` du coffre peut être purgée une fois cette vérification faite.

### Droits du token

Doc source : [Renovate — platform/github](https://docs.renovatebot.com/modules/platform/github/).
Le token actuel est un **fine-grained PAT** (`github_pat_…`).

**Fine-grained PAT** — permissions à cocher :

| Permission        | Niveau         | Scope                  |
| ----------------- | -------------- | ---------------------- |
| Metadata          | Read-only      | Repository (implicite) |
| Contents          | Read and write | Repository             |
| Commit statuses   | Read and write | Repository             |
| Issues            | Read and write | Repository             |
| Pull requests     | Read and write | Repository             |
| Workflows         | Read and write | Repository             |
| Dependabot alerts | Read-only      | Repository             |
| Members           | Read-only      | Organization (si org)  |

**Classic PAT** (alternative) : scope `repo` + `workflow` (ce dernier requis pour bumper les
fichiers GitHub Actions).

**GitHub App** (self-hosted, cf. [doc](https://docs.renovatebot.com/modules/platform/github/#running-as-a-github-app)) :
Checks, Commit statuses, Contents, Issues, Pull requests, Workflows en `read+write` ;
Administration, Dependabot alerts, Members, Metadata en `read`.

### Cibles & configuration

Dépôts scannés = `args` du conteneur (`RENOVATE_AUTODISCOVER: "false"` → liste explicite).
Ajouter/retirer un dépôt = éditer `args` dans
`cluster/app/renovate/manifests/cron-job.yaml`, commit + push.

### État & déclenchement manuel

```bash
kubectl -n renovate get cronjob
kubectl -n renovate get jobs,pods
kubectl create job -n renovate --from=cronjob/renovate renovate-manual   # run ad hoc
kubectl -n renovate logs job/renovate-manual -f
```
