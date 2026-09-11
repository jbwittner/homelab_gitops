# renovate

## Rôle

Mises à jour de dépendances automatisées via [Renovate](https://docs.renovatebot.com/) en mode
self-hosted. **Deux** bots sont écrits dans ce composant, un par forge — mais **un seul est
déployé aujourd'hui** :

| CronJob            | Forge                          | Périmètre                     | Secret                 | Heure (Europe/Paris) | État |
| ------------------ | ------------------------------ | ----------------------------- | ---------------------- | ----- | --- |
| `renovate-github`  | github.com                     | liste explicite (`args`) — `homelab_terraform` seul | `renovate-github`         | **02:00** | **déployé** |
| `renovate-forgejo` | [forgejo](../../../archive/forgejo/README.md) | autodiscover (accès du bot)   | `renovate-forgejo` | **01:00** | **non déployé** — ligne commentée dans `kustomization.yaml`, faute de `SealedSecret` |

> [!NOTE]
> `kubectl -n renovate get cronjob` ne rend donc qu'**une** ligne. Pour activer le second, produire
> `manifests/renovate-forgejo.sealed.yaml` et décommenter **les deux** lignes correspondantes
> (`renovate-forgejo.sealed.yaml` et `cron-job-forgejo.yaml`) dans le même commit — cf.
> §Câblage des secrets.

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
  endpoint **public** `https://forgejo.wittner.tech/` depuis que la forge est hors du cluster,
  `RENOVATE_GIT_URL: endpoint` (secret `renovate-forgejo`)
- `manifests/namespace.yaml` — ns `renovate` (`sync-wave: -1`)
- `manifests/renovate-github.sealed.yaml` — `SealedSecret` du bot GitHub. **Présent et actif** dans
  `kustomization.yaml`
- `manifests/renovate-forgejo.sealed.yaml` — `SealedSecret` du bot Forgejo. **Absent du repo tant
  que le scellement n'a pas été fait** — cf. §Câblage des secrets
- `manifests/*.secret.example.yaml` — templates de scellement, versionnés et sans valeur. Jamais
  dans `kustomization.yaml`
- `manifests/kustomization.yaml` — assemblage. La ligne `renovate-github.sealed.yaml` est
  **active** ; celles du bot Forgejo (`renovate-forgejo.sealed.yaml` et `cron-job-forgejo.yaml`)
  restent **commentées** tant que le fichier scellé n'existe pas — un `resources:` pointant un
  fichier manquant fait échouer le `kustomize build` entier

## Contraintes

- **Les deux CronJobs portent le même tag d'image**, et ce n'est pas cosmétique : le manager
  `kubernetes` de `renovate.json` (`managerFilePatterns: /manifests/.+\.yaml$/`) voit les deux
  fichiers, donc le bump de `renovate/renovate` arrive en **une** PR touchant les deux lignes,
  automergée. Les désaligner casse cette propriété.
- **Les crons sont décalés (Forgejo 01:00, GitHub 02:00) exprès.** Les deux bots consomment le **même** quota
  d'API github.com pour les lookups de releases — `RENOVATE_GITHUB_COM_TOKEN` est présent dans les
  deux Secrets, y compris celui de Forgejo. ⚠️ `concurrencyPolicy: Forbid` ne protège de rien ici :
  il s'applique **par CronJob** et n'empêche pas deux CronJobs distincts de tourner ensemble.
- **Le bot Forgejo sort du cluster comme n'importe quel client depuis le 2026-09-11.** La forge
  est en Docker sur une machine dédiée ([archive/forgejo](../../../archive/forgejo/README.md)) :
  l'ancienne dépendance à la règle d'ingress « bot Renovate » de sa `CiliumNetworkPolicy` n'existe
  plus, et son endpoint est passé de l'adresse interne à `https://forgejo.wittner.tech/`.
  ⚠️ Contrepartie : clone et push repassent par le **tunnel Cloudflare** et son plafond de 100 Mo
  par requête (plan gratuit).
- La politique de mise à jour (cooldown, automerge, managers, chemins ignorés) vit dans
  `renovate.json` **à la racine**, pas ici. Notamment : `internalChecksFilter: strict` est
  load-bearing — sans lui, `ignoreTests: true` rendrait l'automerge immédiat malgré le cooldown.
- **Argo CD n'est jamais automergé** (`packageRules` de `renovate.json`) : il est self-managed,
  un bump raté casse le moteur GitOps lui-même.
- Cilium et les CRDs Gateway API sont proposés indépendamment alors qu'ils sont **couplés** :
  relire la compatibilité avant de merger (cf. [gateway-api](../../infra/gateway-api/README.md)).
- Le namespace `renovate` n'a **pas** de `CiliumNetworkPolicy`, et pas « par oubli » : les deux
  bots ont besoin d'un egress internet large (registres npm, PyPI, Docker Hub, github.com…). En
  poser une par symétrie avec un composant applicatif, sans énumérer ces destinations, coupe les
  lookups. ⚠️ Depuis que la forge est hors du cluster, `forgejo.wittner.tech` fait partie de cet
  egress internet : une policy posée ici devrait aussi l'autoriser.

## Cibles & configuration

### GitHub — liste explicite

`RENOVATE_AUTODISCOVER: "false"` : les dépôts scannés sont les `args` du conteneur. Ajouter ou
retirer un dépôt = éditer `args` dans `manifests/cron-job-github.yaml`, commit + push.

⚠️ **`jbwittner/homelab_gitops` a été retiré de cette liste.** Depuis la bascule de la source du
GitOps vers Forgejo, le dépôt GitHub du même nom n'est plus qu'un **miroir sortant, en lecture
seule** : une PR ouverte dessus serait refusée au push ou écrasée à la synchro suivante du miroir.
C'est le bot Forgejo qui le prend en charge — sans rien à déclarer, l'autodiscover suffit. Il ne
reste donc ici que `jbwittner/homelab_terraform`.

### Forgejo — autodiscover

`RENOVATE_AUTODISCOVER: "true"`, pas d'`args`. Le périmètre n'est **écrit nulle part dans ce
dépôt** : c'est exactement l'ensemble des dépôts auxquels le **compte bot** a accès dans Forgejo.
Le régler = ajouter/retirer ce compte comme collaborateur ou membre d'organisation. Pour le
restreindre sans toucher aux accès : `RENOVATE_AUTODISCOVER_FILTER`.

⚠️ Au premier run, Renovate ouvre une **PR d'onboarding** dans chaque dépôt découvert. C'est le
seul moment où le périmètre réel devient visible : relire la liste avant de merger. Si elle est
trop large, corriger les accès du compte bot plutôt que de fermer les PR une par une.

### Les dépôts scannés sont privés

Les dépôts des deux forges sont **privés**, et le mode d'échec est le même des deux côtés : un
dépôt privé hors du périmètre du jeton répond **`404`**, pas `403`. Le message ne dit donc pas
« accès refusé » mais « inexistant », et ressemble à une faute de frappe. C'est la case à revoir en
premier.

- **GitHub** (`homelab_terraform`) : le PAT est un **fine-grained PAT** scopé au dépôt (§Droits du
  token) — il lit un dépôt privé sans réglage supplémentaire, **à la seule condition que le dépôt
  figure dans sa liste « Repository access »**.
- **Forgejo** (`homelab_gitops` et les autres) : le périmètre, ce sont les accès du **compte bot**
  dans Forgejo. Un dépôt auquel il n'est pas collaborateur est invisible, pas refusé.

⚠️ Cela ne concerne **pas** le `RENOVATE_GITHUB_COM_TOKEN` du Secret **Forgejo** : il ne sert qu'aux
lookups de releases publiques upstream, et reste sans aucune permission.

⚠️ Cela ne concerne pas non plus ArgoCD, qui lit `homelab_gitops` par un canal entièrement distinct
— son propre jeton Forgejo `read:repository`, porté par le Secret `repo-homelab-gitops`, cf.
[argocd](../../infra/argocd/README.md) §Accès au dépôt privé. Deux jetons, deux comptes bots
possibles, deux rotations : les confondre est le piège.

### Le `renovate.json` racine n'est pas hérité

Il ne s'applique qu'à `homelab_gitops`. Les dépôts Forgejo ont chacun le leur, créé par la PR
d'onboarding : `minimumReleaseAge: 7 days` et `internalChecksFilter: strict` **n'y sont pas**, et
donc ni le cooldown de 7 jours ni le filtrage strict. Les y recopier si le comportement voulu est
le même.

### Endpoint Forgejo : public depuis la sortie de la forge du cluster

Le bot joint la forge par `https://forgejo.wittner.tech/` — il n'y a plus de Service à joindre en
interne (forge archivée le 2026-09-11, cf. [archive/forgejo](../../../archive/forgejo/README.md)).

Ce que la bascule a changé, et qu'il faut avoir en tête avant de réactiver ce bot :

- **le chemin passe par le tunnel Cloudflare**, donc par son plafond de **100 Mo par requête**
  (plan gratuit). L'ancien montage joignait l'API en interne *et* clonait en interne précisément
  pour l'éviter ; ce trajet n'existe plus. Un dépôt volumineux peut donc faire échouer le clone ;
- **le jeton ne transite plus en clair** : l'endpoint est en `https://`, là où l'adresse interne
  était en `http://` sur le réseau de pods. C'est le seul gain net de l'opération ;
- `RENOVATE_GIT_URL: endpoint` est **conservé** mais n'a plus d'effet observable : il reconstruit
  l'URL git depuis l'endpoint, lequel coïncide désormais avec le `ROOT_URL` de la forge. Il rend
  le trajet explicite plutôt que dépendant d'un réglage fait sur la machine Docker.

## Opérations

### Câblage des secrets

Canal : **sealed-secrets** (le `SealedSecret` porte la valeur chiffrée, pas un pointeur vers un
coffre). Le contrôleur est en wave `-8`, donc bien avant cette app.

> [!WARNING]
> **État actuel : `renovate-github` est scellé et actif ; `renovate-forgejo` n'existe toujours
> pas.** Seul le bot GitHub est donc produit par ce dépôt, et seule sa ligne est décommentée dans
> `kustomization.yaml`.
>
> Historique, parce qu'il explique le nommage : le bot GitHub a tourné sur un Secret
> **`renovate-env`** — un **orphelin** laissé dans le cluster par l'ancien `ExternalSecret`
> (`deletionPolicy: Retain`), que plus personne ne gérait et que rien ne signalait. Le renommage en
> `renovate-github` a converti cette dérive silencieuse en panne visible
> (`CreateContainerConfigError`), puis le scellement l'a soldée. **Reste à vérifier que l'orphelin
> `renovate-env` a bien été purgé** (§Purger l'orphelin de l'ancien canal).
>
> Le chantier ouvert est désormais le bot **Forgejo** : sceller `renovate-forgejo`, puis décommenter
> `renovate-forgejo.sealed.yaml` **et** `cron-job-forgejo.yaml` dans le même commit.
>
> ⚠️ Un fichier scellé **vide** (0 octet) ne fait PAS échouer le `kustomize build` : kustomize
> l'accepte et ne rend rien. Le dépôt est déjà tombé dans ce piège une fois — un fichier vide était
> committé et référencé, et tout paraissait sain. Vérifier le contenu, pas l'existence.

#### Secret GitHub (`renovate-github`)

Une seule entrée à fournir — le PAT GitHub — mais **deux clés** : Renovate attend le même token
sous `RENOVATE_TOKEN` (plateforme) et `RENOVATE_GITHUB_COM_TOKEN` (lookups de releases sur
github.com). Un `SealedSecret` chiffrant clé par clé, la valeur est saisie deux fois.

⚠️ Ce Secret s'appelait `renovate-env` (nom hérité de l'ancien canal). Le renommage aligne la paire
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

#### Purger l'orphelin de l'ancien canal

Le PAT GitHub est peut-être encore récupérable dans l'orphelin resté au cluster :

```bash
# ⚠️ `renovate-env` : l'ANCIEN nom. L'orphelin du cluster n'a pas été renommé avec le dépôt.
kubectl -n renovate get secret renovate-env -o jsonpath='{.data.RENOVATE_TOKEN}' | base64 -d
```

Une fois le `SealedSecret` en place, vérifier que le Secret `renovate-github` existe bien et
appartient au `SealedSecret` :

```bash
kubectl -n renovate get sealedsecret renovate-github
kubectl -n renovate get secret renovate-github -o jsonpath='{.metadata.ownerReferences}'
```

Puis seulement, purger l'orphelin :

```bash
kubectl -n renovate delete secret renovate-env          # l'ancien, plus référencé par personne
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

1. `platform=forgejo` et l'endpoint `https://forgejo.wittner.tech/` → la config est prise ;
2. `Autodiscovered repositories` avec la liste attendue → jeton et accès du compte bot corrects.
   Liste **vide** = problème d'accès, pas de config ;
3. pas d'erreur TLS ni de 5xx au premier appel API → le chemin sortant (DNS public, edge
   Cloudflare, tunnel, reverse proxy, machine Docker) est complet. ⚠️ **Ce chemin est le point de
   défaillance le plus probable depuis que la forge a quitté le cluster**, et une panne de tunnel
   s'y lit comme un 502/504, pas comme un problème de droits ;
4. un `git clone` qui échoue sur un dépôt volumineux n'est pas un problème de jeton : c'est le
   plafond de **100 Mo par requête** du tunnel Cloudflare (plan gratuit).

⚠️ Il n'y a plus de `CiliumNetworkPolicy` côté forge à interroger — le namespace `forgejo`
n'existe plus. Le diagnostic réseau se fait depuis un pod du cluster, vers l'extérieur :

```bash
kubectl -n renovate run curl --rm -it --restart=Never --image=curlimages/curl -- \
  -sI https://forgejo.wittner.tech/api/v1/version
```
