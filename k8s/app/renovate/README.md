# renovate

## Rôle

Mises à jour de dépendances automatisées via [Renovate](https://docs.renovatebot.com/) en mode
self-hosted. **Un seul bot**, sur github.com, authentifié comme **GitHub App** :

| CronJob           | Plateforme | Périmètre                                         | Secret            | Heure (Europe/Paris) |
| ----------------- | ---------- | ------------------------------------------------- | ----------------- | -------------------- |
| `renovate-github` | github.com | autodiscover = dépôts de l'**installation** de l'App | `renovate-github` | **02:00**            |

Aucune exposition réseau (job batch, pas de service).

Le délai avant qu'un bump soit proposé ne vient **pas** de la cadence du cron mais de
`minimumReleaseAge` (7 jours) dans le `renovate.json` **à la racine du repo** : une release doit
avoir 7 jours révolus avant qu'une branche ou une PR soit créée. ⚠️ Ce fichier ne configure que
**ce dépôt-ci** — voir §Cibles & configuration.

> [!NOTE]
> **Un bot par plateforme.** `platform` est un réglage **global** de Renovate : un même run ne
> peut pas parler à deux hébergeurs de dépôts. En ajouter un second, c'est ajouter un second
> CronJob et son Secret, pas étendre celui-ci. Le bot GitHub est passé d'un fine-grained PAT et
> d'une liste explicite de dépôts (`args`) à une GitHub App en autodiscover.

## Fichiers

- `renovate.app.yaml` — Application (archétype (c), path → `manifests/`)
- `manifests/cron-job-github.yaml` — `CronJob` du bot. Pas d'`args` (autodiscover), réglages en
  `env`, Secret `renovate-github` monté **en volume** sous `/etc/renovate-github-app`
- `manifests/config.mjs` — configuration globale Renovate (`RENOVATE_CONFIG_FILE`). Fabrique à
  chaque run le jeton d'installation de l'App — cf. §Authentification GitHub App
- `manifests/renovate-github.sealed.yaml` — `SealedSecret` de l'App (`app-id`, `installation-id`,
  `private-key.pem`)
- `manifests/renovate-github.secret.example.yaml` — template de scellement et procédure complète
  de création de l'App. Versionné, sans valeur, jamais dans `kustomization.yaml`
- `manifests/namespace.yaml` — ns `renovate` (`sync-wave: -1`)
- `manifests/kustomization.yaml` — assemblage ; `config.mjs` y devient le ConfigMap
  `renovate-github-config-<hash>` (`configMapGenerator`)

## Contraintes

- La politique de mise à jour (cooldown, automerge, managers, chemins ignorés) vit dans
  `renovate.json` **à la racine**, pas ici. Notamment : `internalChecksFilter: strict` est
  load-bearing — sans lui, `ignoreTests: true` rendrait l'automerge immédiat malgré le cooldown.
- **Argo CD n'est jamais automergé** (`packageRules` de `renovate.json`) : il est self-managed,
  un bump raté casse le moteur GitOps lui-même.
- Le bump de `renovate/renovate` est **automergé** (`renovate.json`) : le bot met à jour sa
  propre image. `config.mjs` dépend de deux comportements internes de Renovate — fichier de
  config chargé par `import()` (donc ESM et top-level await permis), et résultat attendu avant
  lecture de `token`. Un bump majeur qui les casserait se lirait au run suivant comme une erreur de
  config (§Diagnostic).
- Cilium et les CRDs Gateway API sont proposés indépendamment alors qu'ils sont **couplés** :
  relire la compatibilité avant de merger (cf. [gateway-api](../../infra/gateway-api/README.md)).
- Le namespace `renovate` n'a **pas** de `CiliumNetworkPolicy`, et pas « par oubli » : le bot a
  besoin d'un egress internet large (registres npm, PyPI, Docker Hub, github.com…). En poser une
  par symétrie avec un composant applicatif, sans énumérer ces destinations, coupe les lookups.

## Cibles & configuration

### Périmètre : l'installation de l'App, réglée dans GitHub

`RENOVATE_AUTODISCOVER: "true"`, pas d'`args`. Le périmètre n'est **écrit nulle part dans ce
dépôt** : avec un jeton d'installation, Renovate liste `/installation/repositories`, soit
exactement les dépôts cochés dans l'installation de l'App (GitHub → Settings → Applications →
Installed GitHub Apps → l'App → Configure → *Only select repositories*). Ajouter ou retirer un
dépôt = le cocher ou le décocher là, **sans commit ici**. La liste n'est volontairement pas
recopiée ici : elle dériverait. Elle se lit dans GitHub, ou en tête de chaque run :

```bash
kubectl -n renovate logs job/<job> | grep -A8 'Autodiscovered repositories'
```

Pourquoi là et pas dans une liste `args` avec une App installée partout : l'installation est
aussi le périmètre des **droits**. Installée sur « All repositories », l'App aurait l'écriture sur
tous les dépôts du compte, et seule une liste dans ce dépôt l'empêcherait de s'en servir. Ici,
ce que Renovate traite et ce que l'App peut écrire sont une seule et même liste.

⚠️ Un dépôt nouvellement coché reçoit une **PR d'onboarding** au run suivant — c'est le moment où
le périmètre réel devient visible. Passer l'installation en « All repositories » la déclencherait
sur **tous** les dépôts du compte.

⚠️ La liste de l'installation n'est **pas** versionnée : elle ne se relit que dans GitHub, ou
dans les logs d'un run (`Autodiscovered repositories`).

### Le `renovate.json` racine n'est pas hérité

Il ne s'applique qu'à `homelab_gitops`. Les autres dépôts ont chacun le leur, créé par la PR
d'onboarding : `minimumReleaseAge: 7 days` et `internalChecksFilter: strict` n'y sont pas
d'office. Les y recopier si le comportement voulu est le même.

### Authentification GitHub App

La CLI Renovate n'accepte qu'un **jeton d'installation** (`ghs_…`, valable 1 h), pas un couple
App ID + clé privée ([doc](https://docs.renovatebot.com/modules/platform/github/#running-as-a-github-app)).
`config.mjs` le produit au démarrage de chaque run, sans initContainer ni image tierce :

1. signe un JWT RS256 avec `private-key.pem` (`iss` = `app-id`) ;
2. `POST /app/installations/<installation-id>/access_tokens` → jeton d'installation.

Il n'exporte que `token`. Le reste découle du préfixe `ghs_` : Renovate se sait GitHub App,
**déduit seul son `gitAuthor`** (`<slug>[bot] <<id>+<slug>[bot]@users.noreply.github.com>`) et
liste les dépôts de l'installation en autodiscover. Conséquences :

- ⚠️ **Ne jamais remettre `RENOVATE_TOKEN` ni `RENOVATE_GIT_AUTHOR` dans l'`env` du CronJob** :
  Renovate fait primer l'environnement sur le fichier de config — le premier écraserait le jeton
  calculé, le second l'identité déduite de l'App, sans erreur dans les deux cas ;
- pas de `RENOVATE_GITHUB_COM_TOKEN` : la plateforme étant github.com, le jeton d'installation sert
  aussi aux lookups de releases (changelogs, `github-releases`, `github-tags`), avec le quota d'API
  d'une installation d'App ;
- le jeton n'est **pas** renouvelé en cours de run. Un run dure ~3 min ; un run qui dépasserait
  l'heure finirait en 401 ;
- rien n'expire côté dépôt : la clé privée de l'App n'a pas de date de fin.

## Opérations

### Droits de la GitHub App

Doc source : [Renovate — platform/github](https://docs.renovatebot.com/modules/platform/github/).
Repository permissions, et **rien d'autre** :

| Permission          | Niveau         | Pourquoi                                                                                   |
| ------------------- | -------------- | ------------------------------------------------------------------------------------------ |
| Metadata            | Read-only      | imposé par GitHub                                                                          |
| Contents            | Read and write | cloner, lire `renovate.json`, pousser les branches `renovate/*`                            |
| Pull requests       | Read and write | ouvrir, mettre à jour, merger les PR (automerge)                                           |
| Issues              | Read and write | issue « Dependency Dashboard » (`config:recommended`), issues d'erreur de config, labels |
| Commit statuses     | Read and write | statut `renovate/stability-days` — c'est lui qui porte le cooldown de 7 jours              |
| Checks              | Read and write | lire les checks CI avant d'automerger                                                      |
| Workflows           | Read and write | modifier `.github/workflows/*` — GitHub refuse le push sans, même avec Contents en écriture |
| Administration      | Read-only      | lire protection de branche et méthodes de merge autorisées. **Jamais** en écriture         |
| Dependabot alerts   | Read-only      | PR de sécurité (`vulnerabilityAlerts`)                                                     |

Volontairement **absents** : *Merge queues* (n'existe que sur les dépôts d'organisation) et
*Members* (organisation — `jbwittner` est un compte personnel).

### Câblage du secret

Canal : **sealed-secrets** (le `SealedSecret` porte la valeur chiffrée, pas un pointeur vers un
coffre). Le contrôleur est en wave `-8`, donc bien avant cette app.

Procédure complète — création de l'App, installation, génération du clair, scellement — dans
l'en-tête de `manifests/renovate-github.secret.example.yaml`. Trois clés, qui sont les noms de
fichiers lus par `config.mjs` : `app-id`, `installation-id`, `private-key.pem`.

> [!WARNING]
> Un fichier scellé **vide** (0 octet) ne fait PAS échouer le `kustomize build` : kustomize
> l'accepte et ne rend rien. Le dépôt est déjà tombé dans ce piège une fois. Vérifier le contenu,
> pas l'existence.

Le `SealedSecret` est chiffré pour le couple (`renovate-github`, `renovate`) : le renommer ou
changer son namespace le rend indéchiffrable. Il l'est aussi pour la clé du contrôleur — un
`sealed-secrets` réinstallé à neuf ne sait plus le déchiffrer.

**Rotation** : nouvelle clé privée côté GitHub, re-scellement, commit, attendre le Secret à jour
dans le cluster, **puis** seulement supprimer l'ancienne clé côté GitHub. La clé est relue à chaque
run : rien à redémarrer.

### État & déclenchement manuel

```bash
kubectl -n renovate get cronjob,jobs,pods
kubectl create job -n renovate --from=cronjob/renovate-github renovate-github-manual
kubectl -n renovate logs job/renovate-github-manual -f
```

### Diagnostic

Une panne d'authentification sort en **une ligne**, avant tout travail de Renovate :

```
renovate-github : authentification GitHub App impossible — <appel> → HTTP <code> <réponse>
```

| Symptôme                                                    | Cause                                                                                   |
| ----------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| `ENOENT … /etc/renovate-github-app/<clé>`                   | clé absente ou mal nommée dans le Secret                                                |
| `HTTP 401` *JSON web token could not be decoded*            | clé privée et `app-id` qui ne vont pas ensemble, ou clé supprimée/révoquée côté GitHub   |
| `HTTP 401` *'Expiration time' claim … is too far in the future* / *issued at in the future* | horloge du nœud décalée de plus d'une minute |
| `HTTP 404` sur `/app/installations/…`                       | `installation-id` faux, ou App désinstallée                                             |
| `Autodiscovered repositories` vide ou incomplet             | dépôt non coché dans l'installation de l'App                                            |
| `Error parsing config file` **sans** la ligne ci-dessus     | Renovate ne charge plus `config.mjs` comme avant — regarder le dernier bump de l'image  |
| push refusé sur `.github/workflows/*`                       | permission *Workflows* manquante                                                        |
