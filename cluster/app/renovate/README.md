# renovate

## Rôle

Mises à jour de dépendances automatisées via [Renovate](https://docs.renovatebot.com/) en mode
self-hosted. **Deux** bots tournent dans ce composant, un par forge :

| CronJob            | Forge                          | Périmètre                     | Secret                 | Heure |
| ------------------ | ------------------------------ | ----------------------------- | ---------------------- | ----- |
| `renovate-github`  | github.com                     | liste explicite (`args`)      | `renovate-github`         | 01:00 |
| `renovate-forgejo` | [forgejo](../forgejo/README.md) | autodiscover (accès du bot)   | `renovate-forgejo` | 02:00 |

**Pourquoi deux et pas un** : `platform` est un réglage **global** de Renovate, pas un réglage par
dépôt. Un même run ne peut pas parler aux deux forges — il faut deux exécutions, deux jetons, deux
Secrets. Aucune exposition réseau (jobs batch, pas de service).

Le délai avant qu'un bump soit proposé ne vient **pas** de la cadence du cron mais de
`minimumReleaseAge` (7 jours) dans le `renovate.json` **à la racine du repo** : une release doit
avoir 7 jours révolus avant qu'une branche ou une PR soit créée. ⚠️ Ce fichier ne configure que
**ce dépôt-ci** — voir §Cibles & configuration.

## Fichiers

- `renovate.app.yaml` — Application (archétype (c), path → `manifests/`). Une seule Application
  pour les deux bots
- `manifests/cron-job-github.yaml` — `CronJob` du bot **GitHub**. Dépôts ciblés en `args`,
  configuration par `env` + `envFrom` (secret `renovate-github`)
- `manifests/cron-job-forgejo.yaml` — `CronJob` du bot **Forgejo**. Pas d'`args` (autodiscover),
  endpoint interne, `RENOVATE_GIT_URL: endpoint` (secret `renovate-forgejo`)
- `manifests/namespace.yaml` — ns `renovate` (`sync-wave: -1`)
- `manifests/renovate-github.sealed.yaml` — `SealedSecret` du bot GitHub. **Absent du repo tant que
  le scellement n'a pas été fait** — cf. §Câblage des secrets
- `manifests/renovate-forgejo.sealed.yaml` — `SealedSecret` du bot Forgejo. Idem
- `manifests/*.secret.example.yaml` — templates de scellement, versionnés et sans valeur. Jamais
  dans `kustomization.yaml`
- `manifests/kustomization.yaml` — assemblage. Les **deux** lignes `*.sealed.yaml` y sont
  commentées tant que les fichiers n'existent pas

## Contraintes

- **Les deux CronJobs portent le même tag d'image**, et ce n'est pas cosmétique : le manager
  `kubernetes` de `renovate.json` (`managerFilePatterns: /manifests/.+\.yaml$/`) voit les deux
  fichiers, donc le bump de `renovate/renovate` arrive en **une** PR touchant les deux lignes,
  automergée. Les désaligner casse cette propriété.
- **Les crons sont décalés (01:00 / 02:00) exprès.** Les deux bots consomment le **même** quota
  d'API github.com pour les lookups de releases — `RENOVATE_GITHUB_COM_TOKEN` est présent dans les
  deux Secrets, y compris celui de Forgejo. ⚠️ `concurrencyPolicy: Forbid` ne protège de rien ici :
  il s'applique **par CronJob** et n'empêche pas deux CronJobs distincts de tourner ensemble.
- **Le bot Forgejo dépend d'une règle d'ingress dans la policy réseau de la forge**
  (`../forgejo/manifests/forgejo-netpol.yaml`, règle « bot Renovate »). Le pod Forgejo est
  default-deny en ingress : sans elle, le bot échoue en **timeout muet**, pas en 403.
- La politique de mise à jour (cooldown, automerge, managers, chemins ignorés) vit dans
  `renovate.json` **à la racine**, pas ici. Notamment : `internalChecksFilter: strict` est
  load-bearing — sans lui, `ignoreTests: true` rendrait l'automerge immédiat malgré le cooldown.
- **Argo CD n'est jamais automergé** (`packageRules` de `renovate.json`) : il est self-managed,
  un bump raté casse le moteur GitOps lui-même.
- Cilium et les CRDs Gateway API sont proposés indépendamment alors qu'ils sont **couplés** :
  relire la compatibilité avant de merger (cf. [gateway-api](../../infra/gateway-api/README.md)).
- Le namespace `renovate` n'a **pas** de `CiliumNetworkPolicy`, et pas « par oubli » : les deux
  bots ont besoin d'un egress internet large (registres npm, PyPI, Docker Hub, github.com…). En
  poser une par symétrie avec forgejo, sans énumérer ces destinations, coupe les lookups.

## Cibles & configuration

### GitHub — liste explicite

`RENOVATE_AUTODISCOVER: "false"` : les dépôts scannés sont les `args` du conteneur. Ajouter ou
retirer un dépôt = éditer `args` dans `manifests/cron-job-github.yaml`, commit + push.

### Forgejo — autodiscover

`RENOVATE_AUTODISCOVER: "true"`, pas d'`args`. Le périmètre n'est **écrit nulle part dans ce
dépôt** : c'est exactement l'ensemble des dépôts auxquels le **compte bot** a accès dans Forgejo.
Le régler = ajouter/retirer ce compte comme collaborateur ou membre d'organisation. Pour le
restreindre sans toucher aux accès : `RENOVATE_AUTODISCOVER_FILTER`.

⚠️ Au premier run, Renovate ouvre une **PR d'onboarding** dans chaque dépôt découvert. C'est le
seul moment où le périmètre réel devient visible : relire la liste avant de merger. Si elle est
trop large, corriger les accès du compte bot plutôt que de fermer les PR une par une.

### Le `renovate.json` racine n'est pas hérité

Il ne s'applique qu'à `homelab_gitops`. Les dépôts Forgejo ont chacun le leur, créé par la PR
d'onboarding : `minimumReleaseAge: 7 days` et `internalChecksFilter: strict` **n'y sont pas**, et
donc ni le cooldown de 7 jours ni le filtrage strict. Les y recopier si le comportement voulu est
le même.

### Endpoint Forgejo : interne, et pourquoi `RENOVATE_GIT_URL: endpoint`

Le bot joint la forge par le Service du cluster
(`http://forgejo-http.forgejo.svc.cluster.local:3000/`), pas par `https://forgejo.wittner.tech`.

Mais **l'endpoint ne suffit pas** : par défaut Renovate clone via le `clone_url` renvoyé par l'API
du dépôt, et Forgejo le bâtit sur son `ROOT_URL`, c'est-à-dire l'URL publique. Sans
`RENOVATE_GIT_URL: endpoint`, l'API serait interne mais le `git clone`/`git push` repartirait par
le tunnel Cloudflare — trajet inutile, et soumis au plafond de 100 Mo par requête du plan gratuit.

Deux conséquences à connaître :

- l'URL de l'endpoint est en `http://` : le jeton Forgejo transite **en clair sur le réseau de
  pods** (le pod Forgejo parle http, TLS est terminé au Gateway) ;
- les liens que Renovate écrit dans ses logs et son Dependency Dashboard pointent l'adresse
  interne, pas `forgejo.wittner.tech`. Ce n'est pas un symptôme, c'est la contrepartie du choix.

## Opérations

### Câblage des secrets

Canal : **sealed-secrets** (le `SealedSecret` porte la valeur chiffrée, pas un pointeur vers un
coffre). Le contrôleur est en wave `-8`, donc bien avant cette app.

> [!WARNING]
> **État actuel : aucun des deux `SealedSecret` n'existe.** Les deux lignes sont commentées dans
> `kustomization.yaml`, donc aucun Secret n'est produit par ce dépôt.
>
> Le bot GitHub tournait jusqu'ici sur un Secret nommé **`renovate-env`** — un **orphelin** laissé
> dans le cluster par l'ancien `ExternalSecret` openbao (`deletionPolicy: Retain`), que plus
> personne ne gérait et que rien ne signalait. Le Secret attendu s'appelle désormais
> `renovate-github` : l'orphelin ne correspond plus, et le Job échoue franchement en
> `CreateContainerConfigError` tant que le scellement n'est pas fait. Le renommage a donc converti
> une dérive silencieuse en panne visible — c'est voulu, mais **cela coupe le bot GitHub d'ici là**.
> Premier chantier à solder ; récupérer le PAT dans l'orphelin avant de le purger (§Reste de
> l'ancien canal openbao).
>
> ⚠️ Un fichier scellé **vide** (0 octet) ne fait PAS échouer le `kustomize build` : kustomize
> l'accepte et ne rend rien. Le dépôt est déjà tombé dans ce piège une fois — un fichier vide était
> committé et référencé, et tout paraissait sain. Vérifier le contenu, pas l'existence.

#### Secret GitHub (`renovate-github`)

Une seule entrée à fournir — le PAT GitHub — mais **deux clés** : Renovate attend le même token
sous `RENOVATE_TOKEN` (plateforme) et `RENOVATE_GITHUB_COM_TOKEN` (lookups de releases sur
github.com). Un `SealedSecret` chiffrant clé par clé, la valeur est saisie deux fois.

⚠️ Ce Secret s'appelait `renovate-env` (nom hérité du canal openbao). Le renommage aligne la paire
`renovate-github` / `renovate-forgejo` — un nom par bot — mais **casse le lien avec l'objet orphelin
du cluster**, qui porte encore l'ancien nom. Voir l'encadré ci-dessus.

#### Secret Forgejo (`renovate-forgejo`)

**Deux clés, deux jetons différents** :

- `RENOVATE_TOKEN` → jeton d'accès **Forgejo** du compte bot (Paramètres → Applications), scopes
  `write:repository`, `write:issue`, `write:user`, `read:organization` ;
- `RENOVATE_GITHUB_COM_TOKEN` → PAT **github.com** en lecture publique seulement (un fine-grained
  PAT sans aucune permission suffit), pour les changelogs et les datasources `github-releases` /
  `github-tags` — dont les dépendances des dépôts Forgejo dépendent aussi. Sans lui, les lookups
  partent en anonyme et se font rate-limiter (60 req/h par IP) : PR sans changelog, et surtout
  updates **silencieusement manquées**.

#### Procédure (identique pour les deux, à faire deux fois)

```bash
# 1. Template en clair (gitignoré via *.secret.yaml)
cp cluster/app/renovate/manifests/renovate-github.secret.example.yaml \
   cluster/app/renovate/manifests/renovate-github.secret.yaml
# (ou renovate-forgejo.secret.example.yaml → renovate-forgejo.secret.yaml)
# renseigner les valeurs — lire les commentaires du template, les deux clés n'ont pas la même
# règle selon la forge

# 2. Sceller
kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
  < cluster/app/renovate/manifests/renovate-github.secret.yaml \
  > cluster/app/renovate/manifests/renovate-github.sealed.yaml

# 3. Supprimer le clair
rm cluster/app/renovate/manifests/renovate-github.secret.yaml
```

4. Décommenter la ligne correspondante dans `manifests/kustomization.yaml`, **dans le même
   commit** que le fichier scellé.

> [!WARNING]
> Ne pas décommenter avant que le fichier existe : un `resources:` pointant un fichier absent fait
> échouer le `kustomize build` **entier** et l'Application part en `ComparisonError` — ni le
> namespace ni les CronJobs ne sont posés.

Chaque `SealedSecret` est chiffré pour le couple (nom, namespace) : le renommer ou changer son
namespace le rend indéchiffrable. Il l'est aussi pour la clé du contrôleur — un `sealed-secrets`
réinstallé à neuf ne sait plus le déchiffrer.

**Rotation** : régénérer le jeton côté forge, puis refaire les étapes 1→3. Le fichier scellé est
remplacé en entier — il faut re-fournir **toutes** les clés, un `SealedSecret` ne se relit pas.

#### Reste de l'ancien canal openbao

Le PAT GitHub est peut-être encore récupérable côté cluster ou coffre :

```bash
# ⚠️ `renovate-env` : l'ANCIEN nom. L'orphelin du cluster n'a pas été renommé avec le dépôt.
kubectl -n renovate get secret renovate-env -o jsonpath='{.data.RENOVATE_TOKEN}' | base64 -d
kubectl -n openbao exec -ti openbao-0 -- bao kv get -field=github_token kv/homelab/renovate
```

Une fois le `SealedSecret` en place, vérifier que le Secret `renovate-github` existe bien et
appartient au `SealedSecret` :

```bash
kubectl -n renovate get sealedsecret renovate-github
kubectl -n renovate get secret renovate-github -o jsonpath='{.metadata.ownerReferences}'
```

Puis seulement, purger l'orphelin et l'entrée du coffre :

```bash
kubectl -n renovate delete secret renovate-env          # l'ancien, plus référencé par personne
# kv/homelab/renovate côté openbao
```

### Droits du token GitHub

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

⚠️ Le PAT du Secret **Forgejo** n'a besoin d'aucune de ces permissions : il ne sert qu'aux lookups
de releases publiques.

### État & déclenchement manuel

```bash
kubectl -n renovate get cronjob                # renovate-github, renovate-forgejo
kubectl -n renovate get jobs,pods

kubectl create job -n renovate --from=cronjob/renovate-github  renovate-github-manual
kubectl create job -n renovate --from=cronjob/renovate-forgejo renovate-forgejo-manual
kubectl -n renovate logs job/renovate-forgejo-manual -f
```

Ce qu'il faut lire dans les logs du bot Forgejo, dans l'ordre :

1. `platform=forgejo` et l'endpoint interne → la config est prise ;
2. `Autodiscovered repositories` avec la liste attendue → jeton et accès du compte bot corrects.
   Liste **vide** = problème d'accès, pas de config ;
3. pas de timeout au premier appel API → la règle netpol côté forgejo est bien posée. **C'est le
   point de défaillance le plus probable**, et son symptôme est une attente longue puis un échec
   réseau, jamais un `403` ;
4. les URLs de clone doivent pointer `forgejo-http.forgejo.svc…` et **pas** `forgejo.wittner.tech`
   → confirme que `RENOVATE_GIT_URL: endpoint` est effectif.

En cas de doute sur la policy réseau :

```bash
kubectl -n forgejo describe ciliumnetworkpolicy forgejo
cilium monitor --type drop -n forgejo     # pendant le run
```
