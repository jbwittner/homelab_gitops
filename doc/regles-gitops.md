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

Ils sont au nombre de six, tous documentés dans le runbook. Aucun autre n'est légitime :

| Geste | Quand | Pourquoi il ne peut pas être GitOps |
|---|---|---|
| `helm install cilium …` | bootstrap d'un cluster, une fois | Sans CNI, ArgoCD ne peut pas démarrer. La release est ensuite **adoptée** par l'Application `<cluster>-cilium`. |
| `kubectl apply -k cluster/infra/argocd/manifests --server-side` | bootstrap du **hub**, une fois | Il faut ArgoCD pour faire du GitOps. Même dossier que l'Application self-managed → convergence immédiate. |
| `kubectl apply -k cluster/infra/argocd-manager/<cluster>/manifests` | bootstrap d'un **spoke**, une fois | Le hub ne peut pas poser l'identité avec laquelle il joindra le cluster : sans elle, il ne le joint pas. Même dossier que l'Application générée → adoption immédiate. |
| `kubectl apply -f cluster/root.yaml` | **une fois pour le repo**, sur le hub | Le point d'entrée de l'app-of-apps ne peut pas se déployer lui-même. Il n'y a plus un tier-1 par cluster : ce geste ne se refait pas à chaque cluster ajouté. |
| `kubectl apply -f sealed-secrets-key-<cluster>.yaml` | DR | La clé privée ne peut pas vivre dans Git, par définition. |
| Mot de passe admin ArgoCD | bootstrap du hub | `argocd-secret` n'est pas dans le kustomize ; le hash survit aux syncs. |

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

- **Jamais** de `kubectl create secret`, jamais de Secret en clair dans Git.
- Canal unique : **SealedSecrets** — chiffrer avec `kubeseal`, committer le `SealedSecret`,
  le contrôleur déchiffre dans le cluster.
- Convention de fichiers, dans le `manifests/` du composant qui consomme le secret :
  - `<name>.secret.yaml` — template en clair, **gitignoré** (`.gitignore` : `*.secret.yaml`),
    à renseigner localement puis à supprimer après scellement ;
  - `<name>.sealed.yaml` — le `SealedSecret`, **committé** et référencé dans le
    `kustomization.yaml`.
- Procédure : [`cluster/infra/sealed-secrets/README.md`](../cluster/infra/sealed-secrets/README.md).

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
> **La clé privée du contrôleur est le seul état non reconstructible du cluster.** Tout le reste
> se redéploie depuis Git ; sans elle, chaque `SealedSecret` du repo est un fichier mort et il
> faut re-provisionner tous les credentials amont. Backup au coffre, hors cluster et hors Git —
> prérequis du [runbook](runbook-bootstrap.md). Une clé **par cluster** : le backup est nommé
> `sealed-secrets-key-<cluster>.yaml`.
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
