# hermes-close

## Rôle

**Copie conforme de [hermes](../hermes/README.md), avec la sortie réseau en défaut-refus.** Même
image, même `config.yaml`, mêmes ressources, mêmes noms d'objets Kubernetes — dans un namespace
distinct, avec une `CiliumNetworkPolicy` en plus.

Le but est comparatif : mesurer ce qu'un agent perd réellement quand on lui coupe l'accès
internet. `hermes` est le témoin libre, `hermes-close` est le témoin contraint. Ses deux seules
sorties sont le fournisseur LLM et Discord.

## Le point de l'expérience

La comparaison ne vaut que si **une seule variable** change. D'où le parti pris du copier-coller
plutôt qu'une factorisation : pas de base commune, pas d'overlay, pas d'ApplicationSet. Deux
arbres indépendants qu'on peut differ ligne à ligne.

```bash
diff -r cluster/app/hermes/manifests cluster/app/hermes-close/manifests
```

Ce diff doit rester court. À la livraison, il contient exactement :

| Écart | Pourquoi |
| --- | --- |
| `namespace: hermes` → `hermes-close` | isolation des deux instances |
| hostnames `hermes*.lan` → `hermes-close*.lan` | un Gateway, deux noms |
| `public_url` et `API_SERVER_CORS_ORIGINS` | découlent des hostnames |
| `hermes-egress.ciliumnetworkpolicy.yaml` | **absent chez `hermes`, présent ici — la variable** |
| `config/SOUL.md` | **absent chez `hermes` — seconde variable, cf. ci-dessous** |
| commentaires | pointent vers l'autre composant |

Tout autre écart qui apparaît dans ce diff est un bug de l'expérience, pas une amélioration.
Changer le modèle, les ressources ou les toolsets d'un seul côté invalide la comparaison.

> [!IMPORTANT]
> **Cette instance n'est pas seulement privée de recherche web.** Elle n'a ni PyPI, ni npm, ni
> GitHub, ni MCP distant, ni aucun host de skill. Un workflow agentique qui échoue ici peut
> échouer parce qu'il ne peut pas *chercher*, ou parce qu'il ne peut pas *installer une
> dépendance* — deux causes très différentes que le montage ne distingue pas.
>
> Si c'est la pertinence de la recherche seule que tu veux mesurer, il faut ouvrir PyPI, GitHub
> et npm des DEUX côtés et ne faire varier que les hosts de recherche. Cf. §Ajouter une
> destination.

## Ce que SOUL.md change à l'expérience

`manifests/config/SOUL.md` dit à l'agent, dès le premier tour, qu'il est dans un réseau fermé :
ce qui est joignable, comment les échecs se présentent (timeout DNS, pas refus explicite), et
qu'il est inutile de réessayer.

**C'est une seconde variable, et il faut en avoir conscience.** Le montage ne compare plus
« agent en ligne » à « agent hors ligne », mais « agent en ligne » à « agent hors ligne **et
informé** ». Les deux questions sont légitimes, ce ne sont pas les mêmes :

| Sans SOUL.md | Avec SOUL.md |
| --- | --- |
| Mesure l'**adaptation** : l'agent découvre la contrainte en accumulant des timeouts | Mesure la **capacité résiduelle** : ce qu'il sait faire en sachant ce dont il dispose |
| Une part des échecs vient de l'obstination à réessayer | Les échecs restants sont attribuables au manque d'information, pas au manque de contexte |
| Coûte des tours et des jetons en tentatives vouées à expirer | Comparaison plus propre à budget de jetons égal |

Pour mesurer l'adaptation plutôt que la capacité résiduelle : retirer `config/SOUL.md` du
`configMapGenerator` **et** la ligne `install` correspondante de l'initContainer. Les deux
ensemble — le fichier retiré du seul ConfigMap ferait échouer l'initContainer, et le pod
bouclerait en `Init:Error`.

Pour rétablir la symétrie dans l'autre sens, poser un `SOUL.md` côté `hermes` avec la même
structure et une section réseau disant la vérité de cette instance-là. Attention : cela modifie
le hash de son ConfigMap, donc **redémarre le pod `hermes` qui tourne**.

## Fichiers

- `hermes-close.app.yaml` — Application (archétype (c), path → `manifests/`). Livré en
  **`.noapp.yaml`** (cf. §Activation).
- `manifests/namespace.yaml` — ns `hermes-close` (`sync-wave: -1`), sans label PodSecurity
  restrictif
- `manifests/hermes-env.sealed.yaml` — `SealedSecret` **propre à ce namespace** (cf. §Câblage
  des secrets)
- `manifests/config/config.yaml` — identique à celui de `hermes`, au `public_url` près
- `manifests/config/SOUL.md` — identité de l'agent : c'est ce qui lui apprend qu'il est dans un
  réseau fermé (cf. §Ce que SOUL.md change à l'expérience)
- `manifests/config/hermes.env` — variables d'environnement **non secrètes** du conteneur,
  assemblées en ConfigMap `hermes-vars`. Identique à celui de `hermes` au
  `API_SERVER_CORS_ORIGINS` près
- `manifests/statefulset.yaml` — 1 replica, PVC `openebs-lvm-thin` 10 Gi, initContainer de semis
- `manifests/service.yaml` — ClusterIP, ports `api` (8642) et `dashboard` (9119)
- `manifests/hermes-httproute.yaml` — `hermes-close.lan.wittner.tech` → dashboard,
  `hermes-close-api.lan.wittner.tech` → API
- `manifests/hermes-egress.ciliumnetworkpolicy.yaml` — **la variable de l'expérience**
- `manifests/kustomization.yaml` — assemblage

Les contraintes de l'image (root au démarrage, ENTRYPOINT s6, `model.default` et non
`model.name`, `_config_version`, ConfigMap à suffixe de hash, PVC RWO…) sont **identiques** et
documentées une seule fois, dans le [README de `hermes`](../hermes/README.md#contraintes). Elles
ne sont pas dupliquées ici : deux copies d'une même contrainte divergent.

## Contraintes propres à ce composant

- **Le `SealedSecret` de `hermes` n'est PAS réutilisable.** Un SealedSecret est chiffré pour le
  couple (nom, namespace) : celui de `hermes` ne se déchiffre que dans le namespace `hermes`.
  Recopié ici, le contrôleur le refuse et le Secret n'est jamais créé — le pod reste en
  `CreateContainerConfigError`, sans que rien ne mentionne le chiffrement.
- **Il faut une SECONDE application Discord.** Deux gateways sur le même token ouvrent deux
  sessions du même bot : Discord les accepte, les deux reçoivent chaque message, les deux
  répondent, et chacune voit l'autre écrire. Impossible d'attribuer une réponse à une instance —
  l'expérience ne mesure plus rien. Créer une seconde application sur le
  [portail développeur](https://discord.com/developers/applications) et l'inviter sur le serveur.
- **L'authentification LLM est à refaire pour cette instance.** Le provider `openai-codex` est en
  `auth_type: oauth_external` : ses jetons vivent dans `/opt/data/auth.json`, sur le PVC. Les
  deux PVC sont distincts, donc deux flux device code à lancer à la main. C'est le seul état que
  Git ne reconstruit pas, des deux côtés.
- **Le premier démarrage est le moment fragile.** La policy est en place dès la création du pod ;
  si l'image ou un plugin tente une sortie non listée au boot, l'échec se présente en timeout DNS,
  pas en refus explicite. Comparer les logs de démarrage avec ceux de `hermes` est le moyen le
  plus rapide de voir ce qui manque.
- **Les deux hostnames doivent être déclarés sur le reverse proxy LAN (192.168.1.50).** Sans ça :
  404, avec un HTTPRoute pourtant `Accepted` et un Service sain. Rien côté cluster ne signale la
  cause.
- **Deux instances = deux fois la consommation LLM.** Requests 500m/1 Gi, limites 2 CPU/4 Gi,
  PVC 10 Gi — pour chacune.

## Opérations

### Câblage des secrets

Canal **sealed-secrets** (cf. [sealed-secrets](../../infra/sealed-secrets/README.md)). Le
template en clair `manifests/hermes-env.secret.yaml` est gitignoré (`*.secret.yaml`) :

```bash
# 1. Remplir les valeurs REMPLACER du template
openssl rand -hex 32
#    ⚠️ API_SERVER_KEY : 16 caractères minimum (la doc amont en annonce 8, à tort)
#    ⚠️ HERMES_DASHBOARD_BASIC_AUTH_SECRET : 16 octets DÉCODÉS minimum — en dessous, le
#       dashboard échoue sur « no auth providers are registered », message qui pointe vers une
#       auth non configurée alors que le vrai problème est une clé trop courte.

# 2. Sceller — noter le namespace dans le chemin, c'est ce qui change tout
kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
  < cluster/app/hermes-close/manifests/hermes-env.secret.yaml \
  > cluster/app/hermes-close/manifests/hermes-env.sealed.yaml

# 3. Jeter le clair, décommenter les DEUX lignes hermes-env.sealed.yaml du kustomization.yaml
#    (celle de `resources:` et celle du `configMapGenerator:`), committer
rm cluster/app/hermes-close/manifests/hermes-env.secret.yaml
```

### Activation

```bash
git mv cluster/app/hermes-close/hermes-close.noapp.yaml \
       cluster/app/hermes-close/hermes-close.app.yaml
```

Ne le faire qu'une fois le `SealedSecret` en place.

Le composant a déjà été activé puis mis hors service une fois (cf. §Décommissionnement). Une
réactivation repart d'un **PVC vide** : l'`hermes auth` ci-dessous est à refaire, et le
`SOUL.md` est re-semé depuis Git.

### Décommissionnement

Inverse de l'activation, mais **en deux commits séparés, dans cet ordre**. Le fichier
`hermes-close.noapp.yaml` porte déjà le finalizer nécessaire — si ce n'était pas le cas :

```bash
# Commit 1 — poser le finalizer, et RIEN d'autre. Ne change rien au déployé.
#   metadata.finalizers: [resources-finalizer.argocd.argoproj.io]

# Attendre la réconciliation par l'app-of-apps, et la VÉRIFIER avant d'aller plus loin :
kubectl -n argocd get app hermes-close -o jsonpath='{.metadata.finalizers}'
#   doit afficher ["resources-finalizer.argocd.argoproj.io"] — compter ~2 min

# Commit 2 — sortir le fichier du glob du bootstrap
git mv cluster/app/hermes-close/hermes-close.app.yaml \
       cluster/app/hermes-close/hermes-close.noapp.yaml
```

Sans finalizer, l'app-of-apps prune l'`Application` et **orpheline tout ce qu'elle gère** :
namespace, StatefulSet, PVC, HTTPRoute et policy restent dans le cluster sans réconciliation.
Avec, la suppression cascade sur les ressources gérées — dont `namespace.yaml`, dont la
disparition emporte le PVC. Ce PVC vient d'un `volumeClaimTemplates` : il n'est pas dans Git,
donc rien d'autre ne le prunerait.

Les deux étapes dans un seul commit reproduisent exactement l'orphelinage qu'on cherche à éviter
— le fichier peut quitter le glob avant que le finalizer n'ait été appliqué.

**Le PVC est détruit.** La `StorageClass` est en `reclaimPolicy: Delete` (cf.
[openebs](../../infra/openebs/README.md)) : le LV est supprimé et l'espace rendu au VG. Sessions,
mémoires, cron et un `SOUL.md` modifié depuis le dashboard n'existent nulle part ailleurs.

À faire à la main, hors Git — retirer les deux hostnames du reverse proxy LAN `192.168.1.50`,
sinon ils continuent d'y pointer dans le vide :

- `hermes-close.lan.wittner.tech`
- `hermes-close-api.lan.wittner.tech`

Si le namespace reste bloqué en `Terminating` :

```bash
kubectl get ns hermes-close -o jsonpath='{.status.conditions}'
kubectl -n hermes-close api-resources --verbs=list -o name \
  | xargs -n1 kubectl -n hermes-close get --show-kind --ignore-not-found
```

### Auth LLM

À faire une fois le pod `Running`, et à refaire si le PVC est perdu :

```bash
kubectl -n hermes-close exec -it sts/hermes -- hermes auth
```

Le flux device code affiche une URL à ouvrir depuis un navigateur — c'est bien la machine de
l'opérateur qui la contacte, pas le pod. La policy ne gêne pas cette étape ; seul le
rafraîchissement du jeton (`auth.openai.com`) part du pod, et il est autorisé.

### État & accès

```bash
kubectl -n hermes-close get statefulset,pod,pvc
kubectl -n hermes-close logs sts/hermes -f      # gateway et dashboard sont interleavés
kubectl -n hermes-close get cnp hermes-egress
```

- Dashboard : <https://hermes-close.lan.wittner.tech>
- API : `https://hermes-close-api.lan.wittner.tech/v1/...`

### Vérifier que la variable est bien la variable

Le test qui valide le montage expérimental — la même commande des deux côtés, deux résultats
opposés :

```bash
# hermes : doit répondre 200
kubectl -n hermes exec sts/hermes -- \
  curl -sS -m5 https://example.com -o /dev/null -w '%{http_code}\n'

# hermes-close : doit échouer (résolution DNS refusée par le proxy L7 de Cilium)
kubectl -n hermes-close exec sts/hermes -- \
  curl -sS -m5 https://example.com -o /dev/null -w '%{http_code}\n'
```

Si les deux répondent 200, la policy n'est pas appliquée côté live. Voir ce qui tombe, depuis un
pod cilium :

```bash
cilium monitor --type drop -n hermes-close
```

### Ajouter une destination

**Deux endroits dans le même fichier, jamais un seul** : le `matchName` sous `rules.dns` **et**
le `toFQDNs`. Le proxy DNS de Cilium ne débloque une IP que pour un nom qu'il a lui-même vu
résoudre ; un `toFQDNs` orphelin ne matche rien, et le symptôme est un timeout réseau, pas un
refus explicite.

Et se rappeler que chaque ajout déplace la frontière qu'on mesure. Pour isoler la recherche web
du reste, la manœuvre correcte est d'ouvrir PyPI, npm et GitHub **des deux côtés** — donc de
recréer une policy équivalente côté `hermes` — et non d'élargir celle-ci seule.

### Sauvegarde

Rien à sauvegarder ici : les sessions et mémoires de cette instance sont des données
d'expérience, pas de production. Le PVC de `hermes`, lui, reste le candidat velero.
