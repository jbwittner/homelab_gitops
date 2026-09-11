# Règles GitOps — NON négociables

## Aucune donnée hors GitOps

**Interdit de pousser des données au cluster hors GitOps.**

- Toute ressource (Application, Deployment, Service, Gateway, HTTPRoute, ConfigMap, Secret,
  cert TLS…) vit dans **Git** et est appliquée par **ArgoCD**. Jamais de `kubectl apply/create`
  impératif.
- Une modif = éditer le manifeste, commit, push. ArgoCD (self-heal) converge. Pas de dérive
  manuelle.

## Périmètre autorisé de `kubectl`

`kubectl` en écriture est réservé à **deux cas**, rien d'autre :

1. **Bootstrap initial** — cf. [runbook](runbook-bootstrap.md) et
   [`cluster/infra/argocd/README.md`](../cluster/infra/argocd/README.md).
2. **Debug read-only** — `get`, `describe`, `logs`, `diff`.

### Les gestes impératifs assumés (et leur périmètre exact)

Ils sont au nombre de **cinq**, tous documentés dans le runbook. Aucun autre n'est légitime :

| Geste | Quand | Pourquoi il ne peut pas être GitOps |
|---|---|---|
| `helm install cilium …` | bootstrap, une fois | Sans CNI, ArgoCD ne peut pas démarrer. La release est ensuite **adoptée** par l'Application `cilium`. |
| `kubectl apply -k cluster/infra/argocd/manifests --server-side` | bootstrap, une fois | Il faut ArgoCD pour faire du GitOps. Même dossier que l'Application self-managed → convergence immédiate. |
| `kubectl apply -f .../repo-homelab-gitops.secret.yaml` | bootstrap, une fois | Le dépôt est **privé** : sans ce credential SSH, `argocd-repo-server` ne peut cloner ni `root.yaml` ni quoi que ce soit. Repris ensuite en gestion par son `SealedSecret`. |
| `kubectl apply -f cluster/root.yaml` | **une fois pour le repo** | Le point d'entrée de l'app-of-apps ne peut pas se déployer lui-même. |
| `kubectl apply -f sealed-secrets-key.yaml` | DR | La clé privée ne peut pas vivre dans Git, par définition. |

Le mot de passe admin ArgoCD se fixe aussi à la main au bootstrap (`argocd-secret` n'est pas dans
le kustomize, le hash survit aux syncs) — c'est une écriture dans un objet existant, pas une
création de ressource. Le restart one-shot de `cilium-operator` (1re pose des CRDs Gateway API) est
un **événement de bootstrap**, pas une écriture d'état.

## Enregistrement du cluster — jamais impérativement

Le cluster n'existe pour ArgoCD que par son **Secret de cluster** (`cluster-bleu-kalecgos`, label
`argocd.argoproj.io/secret-type: cluster`) dans le namespace `argocd`. Il vit dans
[`cluster/infra/argocd/manifests/`](../cluster/infra/argocd/manifests/), donc dans Git, **en clair**
— il ne porte aucun credential (cf. exceptions ci-dessous).

⚠️ `argocd cluster add` fait le même travail **impérativement** : le Secret n'existe alors que dans
le cluster et disparaît au premier rebuild. Interdit.

## Dépôt public

Ce dépôt est **public** : le dépôt Forgejo est en lecture anonyme, servi par le tunnel Cloudflare.
Tout ce qui y entre est lisible de tous, et **définitivement** — un fichier retiré plus tard survit
dans les clones et les caches.

Le **miroir push vers `github.com/jbwittner/homelab_gitops`** reste **privé**. Il part à chaque
commit, sans action manuelle, et une réécriture d'historique ici s'y propage aussi : il ne demande
donc aucun geste propre. Il n'est pas non plus une sauvegarde indépendante — il reflète ce dépôt,
y compris ses réécritures.

La publication ne change rien à deux choses : les `SealedSecret` restent sûrs (chiffrés pour la clé
du contrôleur, qui n'est pas ici), et les `.secret.example.yaml` aussi (ils ne portent que
`REMPLACER`).

⚠️ **Corriger une fuite demande de RÉÉCRIRE l'historique, jamais de commiter par-dessus.**
`git commit --amend` ou un squash, puis `git push --force origin main`. Un commit correctif laisse
la valeur lisible dans le diff du commit fautif — c'est-à-dire publiée.

⚠️ **Et le force-push ne suffit pas côté serveur.** Forgejo garde les objets injoignables jusqu'au
GC : sur un dépôt public, l'ancien commit reste servi par SHA à qui connaît l'URL
(`/commit/<sha>`). Après toute réécriture, lancer le GC du dépôt — Site Administration →
Maintenance, ou sur le dépôt bare de la machine Docker :

```bash
git -C /data/git/repositories/jbwittner/homelab_gitops.git reflog expire --expire-unreachable=now --all
git -C /data/git/repositories/jbwittner/homelab_gitops.git gc --prune=now
```

puis **vérifier** que l'ancien SHA est mort, au lieu de le supposer :

```bash
curl -so /dev/null -w '%{http_code}\n' https://forgejo.wittner.tech/jbwittner/homelab_gitops/commit/<sha>
# attendu : 404
```

⚠️ **La clé privée sealed-secrets change de nature.** Elle était déjà l'état non reconstructible
n°1 (cf. §Secrets). Elle devient le point unique qui, s'il fuit, déchiffre **rétroactivement** tous
les blobs publiés — y compris ceux qu'une rotation ultérieure remplacerait ici, puisque les anciens
survivent dans les clones. Une fuite de cette clé ne se solde donc plus par « resceller », mais par
**tourner tous les credentials à la source** : Cloudflare, GCS, Brevo, Discord, Renovate, Grafana.

⚠️ **Publié en clair, et assumé.** La topologie LAN (`192.168.1.0/24`, pool `.80-.89`, proxy
`.50`), les hostnames, les noms de buckets et le projet GCP `homelab-499008`, le login SMTP Brevo
d'Alertmanager (`helm-values.yaml` de kube-prometheus-stack, qui dit pourquoi il y reste). Aucun
n'est un credential ; tous réduisent le coût de reconnaissance d'un attaquant. La protection est
ailleurs — ACL des buckets, mots de passe scellés, et aucune route publique vers le cluster
(cf. [`reseau.md`](reseau.md)).

⚠️ **La forge publique est AUSSI la source du GitOps.** Le clone anonyme met du trafic non
authentifié sur le composant dont dépend toute capacité à déployer. Deux conséquences qui ne se
règlent pas dans ce dépôt : l'inscription reste fermée (`[service] DISABLE_REGISTRATION = true`
dans l'`app.ini` de la machine Docker), et le tunnel Cloudflare porte la limitation de débit — le
clone est l'endpoint le plus coûteux de Forgejo.

Avant chaque commit, la question n'est plus « est-ce que ça marche » mais **« est-ce que n'importe
qui peut le lire »**. Trois formes admises, et rien d'autre : `SealedSecret`,
`.secret.example.yaml` vide, et les deux coquilles de Secret listées en §Secrets.

### Bascule : les gestes hors dépôt

⚠️ **Le passage en public est le DERNIER geste.** Les règles ci-dessus valent dès maintenant ; la
bascule elle-même suit cet ordre, et chaque étape se vérifie avant la suivante.

1. Masquage du login Brevo d'archive et réécriture du commit → force-push.
2. GC du dépôt Forgejo, puis 404 confirmé sur l'ancien SHA (commandes ci-dessus).
3. ACL des buckets : aucun binding `allUsers` / `allAuthenticatedUsers` sur
   `homelab-velero-backups-b788806f`, `homelab-cnpg-backups-8b8ff253`,
   `homelab-openbao-snapshots-6d84c670`. Leur suffixe aléatoire cesse d'être une protection le
   jour où le dépôt est lisible.
4. `app.ini` et tunnel Cloudflare : inscription fermée, limitation de débit.
5. Dépôt Forgejo en public.

## Secrets

**Jamais** de `kubectl create secret`, jamais de Secret en clair dans Git.

### Un seul canal actif : sealed-secrets

> [!IMPORTANT]
> **Le second canal est mort.** Ce dépôt a eu deux canaux : sealed-secrets, et un backend de
> secrets externe consommé via external-secrets. Le backend a été **retiré du dépôt**, et
> [external-secrets](../cluster/infra/external-secrets/README.md) est en `.noapp.yaml` : la CRD
> `ExternalSecret` n'existe plus dans le cluster. Les quatre `*.externalsecret.yaml` qui subsistent
> sont des **vestiges inertes** — non référencés, et pointant un `ClusterSecretStore` supprimé.
>
> **Tout secret est donc un `SealedSecret`.** Le critère de choix entre deux canaux n'a plus
> d'objet ; ce qui suit décrit le canal restant.

Chiffrer avec `kubeseal`, committer le `SealedSecret`, le contrôleur déchiffre dans le cluster.
Fichiers, dans le `manifests/` du composant consommateur :

- `<name>.secret.yaml` — template en clair, **gitignoré** (`.gitignore` : `*.secret.yaml`),
  à renseigner localement puis à supprimer après scellement ;
- `<name>.secret.example.yaml` — la copie de référence, **versionnée et vide de toute valeur**,
  porteuse de la procédure. Jamais dans le `kustomization.yaml` ;
- `<name>.sealed.yaml` — le `SealedSecret`, **committé** et référencé dans le `kustomization.yaml`.

Procédure : [`cluster/infra/sealed-secrets/README.md`](../cluster/infra/sealed-secrets/README.md).

⚠️ **Décommenter la ligne du `kustomization.yaml` DANS LE MÊME COMMIT que le fichier scellé.** Un
`resources:` pointant un fichier absent fait échouer le `kustomize build` **entier**, donc
l'Application. Et un fichier scellé **vide** (0 octet) ne fait PAS échouer le build : kustomize
l'accepte et ne rend rien. Vérifier le contenu, pas l'existence — ce dépôt est déjà tombé dans ce
piège.

Neuf fichiers, neuf documents `SealedSecret` : `cloudflare-api-token`, `velero-gcs`,
`repo-homelab-gitops`, `argocd-oidc`, `argocd-notifications-secret`, `grafana-admin`,
`alertmanager-smtp`, `hermes-env`, `renovate-github`.

⚠️ **Quatre ont disparu de cette liste le 2026-09-11** — `forgejo-admin` (3 documents),
`forgejo-secrets`, `forgejo-smtp` et `forgejo-db-gcs` : la forge a quitté le cluster
([archive/forgejo](../archive/forgejo/README.md)) et ses secrets vivent désormais dans l'`app.ini`
de sa machine Docker. Les fichiers scellés restent dans `archive/`, **inertes** — ils ne sont plus
appliqués par personne, et ne seraient de toute façon déchiffrables que dans le namespace
`forgejo`, qui n'existe plus.

Trois autres sont **attendus**, tous dans le ns `monitoring` et tous pour des cibles hors cluster :

| Secret | Composant | Cible |
|---|---|---|
| `forgejo-metrics` | [forgejo-monitoring](../cluster/app/forgejo-monitoring/README.md) | token `Bearer` du `/metrics` de la forge |
| `forgejo-db-metrics` | [forgejo-monitoring](../cluster/app/forgejo-monitoring/README.md) | `basicAuth` du `postgres-exporter` |
| `node-exporters` | [hosts-monitoring](../cluster/app/hosts-monitoring/README.md) | `basicAuth` des `node-exporter` des machines hors cluster |

⚠️ **Les deux derniers ne sont pas fusionnés, alors que leurs exportateurs tournent sur LA MÊME
MACHINE.** Ce n'est pas une isolation cryptographique — ce serait illusoire, même hôte, même
`docker inspect` — c'est une **indépendance de cycle de vie** : la supervision d'une machine survit
au service qu'elle héberge, donc retirer la forge du parc doit pouvoir supprimer ses Secrets sans
toucher à l'autre. Un secret partagé aurait réintroduit exactement le couplage que la séparation
des deux composants sert à défaire.

⚠️ **Leur porter la même valeur ne casse rien**, et c'est ce qui est fait aujourd'hui : deux Secrets
distincts restent deux objets qu'on crée, tourne et supprime séparément. Le seul coût est qu'une
fuite de l'un expose l'autre — ce qui était déjà vrai, les deux exportateurs partageant l'hôte, le
démon Docker et le groupe `docker`. Les diverger reste possible à tout moment, sans toucher au
reste.

⚠️ Leurs lignes sont **commentées** dans les `kustomization.yaml` tant qu'ils ne sont pas produits.
Conséquence non intuitive : tant que `node-exporters` manque, ce sont les trois alertes de
sauvegarde de **forgejo-monitoring** qui sont aveugles — elles transitent par le scrape de
hosts-monitoring (collecteur `textfile` de node-exporter).

⚠️ Les deux `basicAuth` ne se **récupèrent pas** depuis la machine s'ils sont perdus : côté hôte,
ils n'existent que sous forme de hachage bcrypt. Il faut en tirer un neuf et refaire les deux copies
(le Secret ici, le `web-config.yml` là-bas).

> [!NOTE]
> **Exceptions admises à « pas de `kind: Secret` dans Git » — un Secret dont le manifeste ne porte
> aucun credential.** Deux formes, deux cas, et rien d'autre :
> - **Coquille annotée pour un contrôleur** :
>   [`argocd-notifications-secret.yaml`](../cluster/infra/argocd/manifests/argocd-notifications-secret.yaml),
>   qui ne porte que `sealedsecrets.bitnami.com/managed: "true"` sur le Secret livré vide par
>   l'upstream — sans quoi le contrôleur sealed-secrets refuse d'y écrire.
> - **Secret de cluster du cluster local** :
>   [`cluster-bleu-kalecgos.yaml`](../cluster/infra/argocd/manifests/cluster-bleu-kalecgos.yaml).
>   Son `stringData` ne porte qu'un nom, l'URL interne `https://kubernetes.default.svc` et
>   `{"tlsClientConfig":{"insecure":false}}` : sur cette adresse ArgoCD se connecte via son propre
>   ServiceAccount et **ignore** toute identité qu'on y mettrait. Rien à sceller.
>
> Toute autre forme de Secret committé reste interdite.

> [!CAUTION]
> **Deux états non reconstructibles depuis Git.**
>
> 1. **La clé privée du contrôleur sealed-secrets.** Sans elle, les neuf `SealedSecret` du repo
>    sont des fichiers morts — donc l'accès au dépôt, les credentials GCS des deux chaînes de
>    sauvegarde, le compte admin de la forge. Backup hors cluster et hors Git,
>    `sealed-secrets-key.yaml`. ⚠️ La rotation automatique de la clé est **coupée**
>    (`keyrenewperiod: "0"`) : une seule clé à sauvegarder, mais aucune marge si elle est perdue.
> 2. **Les clés de compte de service GCP** des buckets velero et barman-cloud. Elles ne se sortent
>    pas d'un état Terraform sans l'y stocker en clair ; elles sont scellées ici, donc protégées
>    par (1) — mais une clé sealed-secrets perdue oblige à en **réémettre** de nouvelles côté GCP,
>    pas à les récupérer.
>
> Corollaire, et c'est le point de défaillance unique du plan de reprise : **sur un cluster
> reconstruit à neuf, restaurer la clé sealed-secrets vient AVANT toute tentative de restauration
> velero ou barman** — sans elle, `velero-gcs` et `forgejo-db-gcs` sont indéchiffrables et plus
> rien ne se restaure. Cf. [`forgejo-pra.md`](forgejo-pra.md) §4.

## Commandes de la documentation

Toute commande écrite dans la doc doit tourner **depuis la racine du repo**, telle quelle :
chemins relatifs à la racine, jamais au dossier du README qui la porte. Une commande qui suppose un
`cd` préalable est à corriger.

## Dépannage impératif

Si un état a été créé impérativement en dépannage (ex. secret self-signed temporaire), il doit être
**remplacé par son équivalent GitOps** (SealedSecret, manifeste committé) puis supprimé du cluster.
Aucun état impératif ne doit survivre.
