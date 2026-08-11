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

Ils sont au nombre de sept, tous documentés dans le runbook. Aucun autre n'est légitime :

| Geste | Quand | Pourquoi il ne peut pas être GitOps |
|---|---|---|
| `helm install cilium …` | bootstrap d'un cluster, une fois | Sans CNI, ArgoCD ne peut pas démarrer. La release est ensuite **adoptée** par l'Application `<cluster>-cilium`. |
| `kubectl apply -k cluster/infra/argocd/manifests --server-side` | bootstrap du **hub**, une fois | Il faut ArgoCD pour faire du GitOps. Même dossier que l'Application self-managed → convergence immédiate. |
| `kubectl apply -k cluster/infra/argocd-manager/<cluster>/manifests` | bootstrap d'un **spoke**, une fois | Le hub ne peut pas poser l'identité avec laquelle il joindra le cluster : sans elle, il ne le joint pas. Même dossier que l'Application générée → adoption immédiate. |
| `kubectl apply -f cluster/root.yaml` | **une fois pour le repo**, sur le hub | Le point d'entrée de l'app-of-apps ne peut pas se déployer lui-même. Il n'y a plus un tier-1 par cluster : ce geste ne se refait pas à chaque cluster ajouté. |
| `kubectl apply -f sealed-secrets-key-<cluster>.yaml` | DR | La clé privée ne peut pas vivre dans Git, par définition. |
| Mot de passe admin ArgoCD | bootstrap du hub | `argocd-secret` n'est pas dans le kustomize ; le hash survit aux syncs. |
| `bao operator unseal` | **à chaque redémarrage** du pod openbao | Les clés de descellement ne peuvent pas vivre dans le cluster qu'elles protègent. Seul geste impératif **récurrent** de la liste — et il ne crée aucune ressource, il débloque la lecture du PVC. |

Le restart one-shot de `cilium-operator` (1re pose des CRDs Gateway API) est un **événement de
bootstrap**, pas une écriture d'état : il ne crée ni ne modifie aucune ressource.

## Enregistrement d'un cluster — jamais impérativement

Un cluster n'existe pour ArgoCD que par son **Secret de cluster** (`cluster-<cluster>`, label
`argocd.argoproj.io/secret-type: cluster`) dans le namespace `argocd` du hub. Il vit dans
[`cluster/infra/argocd/manifests/`](../cluster/infra/argocd/manifests/), donc dans Git :

- cluster **local** (le hub) : Secret en clair, il ne porte aucun credential (cf. exceptions
  ci-dessous) ;
- cluster **distant** (spoke) : `SealedSecret`, il porte le bearer token du ServiceAccount
  `argocd-manager`.

⚠️ `argocd cluster add` fait le même travail **impérativement** : le Secret n'existe alors que
dans le cluster et disparaît au premier rebuild du hub. Interdit.

## Secrets

**Jamais** de `kubectl create secret`, jamais de Secret en clair dans Git. Deux canaux, et deux
seulement.

### Quel canal pour quel secret

La question n'est pas une préférence, c'est une **position dans le graphe de bootstrap**. Le
canal openbao suppose, pour livrer un seul secret : OpenEBS (StorageClass) → openbao (PVC) →
**un descellement manuel** → la config du coffre (repo Terraform) → ESO. Cette chaîne se
termine en wave `1` **plus un geste humain**.

> **Un secret consommé en amont de cette chaîne, ou dont l'indisponibilité doit être exclue,
> est un `SealedSecret`. Tout le reste va dans openbao.**

Ce critère laisse **deux** SealedSecrets dans le repo, et c'est un plancher, pas un objectif de
confort — descendre à zéro exigerait un auto-unseal (KMS, ou transit d'un second coffre),
indisponible ici :

| SealedSecret | Pourquoi il ne peut pas venir du coffre |
|---|---|
| `cloudflare-api-token` ([cert-manager-config](../cluster/infra/cert-manager-config/README.md)) | Consommé en wave `-4`, **avant** qu'openbao existe. Surtout : le renouvellement Let's Encrypt (tous les 60 j) échouerait chaque fois que le coffre est scellé — c'est-à-dire après chaque redémarrage de son pod, donc à chaque upgrade de son chart. |
| `cluster-bleu-arcanagos` ([argocd](../cluster/infra/argocd/README.md)) | C'est ce qui fait *exister* le spoke pour ArgoCD. Requis à l'**étape 2bis** du [runbook](runbook-bootstrap.md), donc avant le tier-1 — openbao n'est pas encore déployé. Absent, toutes les Applications du spoke tombent en `ComparisonError: cluster not found`. |

⚠️ **Règle anti-cycle, valable pour tout secret futur** : un secret dont **openbao ou ESO** a
besoin pour fonctionner ne peut pas venir d'openbao. Le cas concret à venir est le CronJob de
snapshot du coffre vers S3/MinIO : ses credentials devront être scellés, sinon la sauvegarde du
coffre dépend du coffre.

### Canal 1 — SealedSecrets (dans Git)

Chiffrer avec `kubeseal`, committer le `SealedSecret`, le contrôleur déchiffre dans le cluster.
Fichiers, dans le `manifests/` du composant consommateur :

- `<name>.secret.yaml` — template en clair, **gitignoré** (`.gitignore` : `*.secret.yaml`),
  à renseigner localement puis à supprimer après scellement ;
- `<name>.sealed.yaml` — le `SealedSecret`, **committé** et référencé dans le
  `kustomization.yaml`.

Procédure : [`cluster/infra/sealed-secrets/README.md`](../cluster/infra/sealed-secrets/README.md).

### Canal 2 — openbao via external-secrets (hors Git)

La valeur vit dans le coffre ([openbao](../cluster/infra/openbao/README.md)) ; le repo ne
contient qu'un **pointeur** vers elle, sans aucun chiffré. Fichier, dans le `manifests/` du
composant consommateur :

- `<name>.externalsecret.yaml` — l'`ExternalSecret`, committé et référencé dans le
  `kustomization.yaml`. Pas de pendant en clair : il n'y a rien à sceller.

Le secret lui-même se pose au coffre (`bao kv put`, cf.
[openbao](../cluster/infra/openbao/README.md)), pas dans Git. `deletionPolicy: Retain` est
**obligatoire** : sans lui, un coffre scellé supprimerait les `Secret` déjà livrés.

Procédure et diagnostic :
[`cluster/infra/external-secrets/README.md`](../cluster/infra/external-secrets/README.md).

> [!NOTE]
> **Ce que ce canal change, et ce qu'il ne change pas.** Il ne réduit pas la surface de DR : il
> la déplace. Avant, un seul élément non reconstructible (la clé sealed-secrets) ; désormais
> deux, la clé (qui protège encore les deux secrets ci-dessus) **et** le couple clés de
> descellement + snapshot raft, qui porte maintenant six credentials. Le gain réel est la
> **rotation** : changer un secret devient un `bao kv put`, sans commit, sans `kubeseal` et sans
> redéploiement.

> [!NOTE]
> **Exceptions admises à « pas de `kind: Secret` dans Git » — un Secret dont le manifeste ne
> porte aucun credential.** Deux formes, deux cas, et rien d'autre :
> - **Coquille remplie par un contrôleur du cluster** : ni `data:` ni `stringData:` dans le
>   manifeste. Cas unique : `argocd-manager-token`
>   ([`cluster/infra/argocd-manager`](../cluster/infra/argocd-manager/README.md)),
>   rempli par le token controller. Exige un `ignoreDifferences` sur `/data`.
> - **Secret de cluster du cluster local** : `cluster-bleu-kalecgos`
>   ([`cluster/infra/argocd/manifests/cluster-bleu-kalecgos.yaml`](../cluster/infra/argocd/manifests/cluster-bleu-kalecgos.yaml)),
>   qui nomme le cluster hébergeant l'ArgoCD. Son `stringData` ne porte qu'un nom, l'URL interne
>   `https://kubernetes.default.svc` et `{"tlsClientConfig":{"insecure":false}}` : sur cette
>   adresse ArgoCD se connecte via son propre ServiceAccount et **ignore** toute identité qu'on y
>   mettrait. Rien à sceller. Le Secret de cluster d'un **spoke**, lui, porte un bearer token :
>   `SealedSecret` obligatoire (`cluster-bleu-arcanagos`).
>
> Toute autre forme de Secret committé reste interdite.

> [!CAUTION]
> **Deux états non reconstructibles depuis Git, et ils se cumulent.**
>
> 1. **La clé privée du contrôleur sealed-secrets.** Sans elle, les `SealedSecret` du repo sont
>    des fichiers morts — aujourd'hui le token Cloudflare et le Secret de cluster du spoke.
>    Backup au coffre, hors cluster et hors Git. Une clé **par cluster** : le backup est nommé
>    `sealed-secrets-key-<cluster>.yaml`.
> 2. **Les clés de descellement d'openbao et le contenu de son PVC.** Ils portent désormais les
>    six autres secrets du cluster. Un snapshot raft sans les clés de descellement est
>    illisible : les deux sont à sauvegarder, séparément.
>
> Les deux sont des prérequis du [runbook](runbook-bootstrap.md), pas des options. Tout le reste
> se redéploie depuis Git.
>
> Un cluster **spoke** n'a pas de contrôleur sealed-secrets à lui : ses secrets, y compris son
> Secret de cluster, sont scellés avec la clé **du hub**. Il n'y a donc rien à sauvegarder de son
> côté — mais la perte de la clé du hub emporte aussi ses secrets.

## Commandes de la documentation

Toute commande écrite dans la doc doit tourner **depuis la racine du repo**, telle quelle :
chemins relatifs à la racine, jamais au dossier du README qui la porte. Une commande qui
suppose un `cd` préalable est à corriger.

## Dépannage impératif

Si un état a été créé impérativement en dépannage (ex. secret self-signed temporaire), il doit
être **remplacé par son équivalent GitOps** (SealedSecret, manifeste committé) puis supprimé du
cluster. Aucun état impératif ne doit survivre.
