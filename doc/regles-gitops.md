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
   [`bleu-kalecgos/infra/argocd/README.md`](../bleu-kalecgos/infra/argocd/README.md).
2. **Debug read-only** — `get`, `describe`, `logs`, `diff`.

### Les gestes impératifs assumés (et leur périmètre exact)

Ils sont au nombre de quatre, tous documentés dans le runbook. Aucun autre n'est légitime :

| Geste | Quand | Pourquoi il ne peut pas être GitOps |
|---|---|---|
| `helm install cilium …` | bootstrap, une fois | Sans CNI, ArgoCD ne peut pas démarrer. La release est ensuite **adoptée** par l'Application `cilium`. |
| `kubectl apply -k …/argocd/manifests --server-side` | bootstrap, une fois | Il faut ArgoCD pour faire du GitOps. Même dossier que l'Application self-managed → convergence immédiate. |
| `kubectl apply -f sealed-secrets-key-<cluster>.yaml` | DR | La clé privée ne peut pas vivre dans Git, par définition. |
| Mot de passe admin ArgoCD | bootstrap | `argocd-secret` n'est pas dans le kustomize ; le hash survit aux syncs. |

Le restart one-shot de `cilium-operator` (1re pose des CRDs Gateway API) est un **événement de
bootstrap**, pas une écriture d'état : il ne crée ni ne modifie aucune ressource.

## Secrets

- **Jamais** de `kubectl create secret`, jamais de Secret en clair dans Git.
- Canal unique : **SealedSecrets** — chiffrer avec `kubeseal`, committer le `SealedSecret`,
  le contrôleur déchiffre dans le cluster.
- Convention de fichiers, dans le `manifests/` du composant qui consomme le secret :
  - `<name>.secret.yaml` — template en clair, **gitignoré** (`.gitignore` : `*.secret.yaml`),
    à renseigner localement puis à supprimer après scellement ;
  - `<name>.sealed.yaml` — le `SealedSecret`, **committé** et référencé dans le
    `kustomization.yaml`.
- Procédure : [`bleu-kalecgos/infra/sealed-secrets/README.md`](../bleu-kalecgos/infra/sealed-secrets/README.md).

> [!CAUTION]
> **La clé privée du contrôleur est le seul état non reconstructible du cluster.** Tout le reste
> se redéploie depuis Git ; sans elle, chaque `SealedSecret` du repo est un fichier mort et il
> faut re-provisionner tous les credentials amont. Backup au coffre, hors cluster et hors Git —
> prérequis du [runbook](runbook-bootstrap.md). Une clé **par cluster** : le backup est nommé
> `sealed-secrets-key-<cluster>.yaml`.

## Commandes de la documentation

Toute commande écrite dans la doc doit tourner **depuis la racine du repo**, telle quelle :
chemins relatifs à la racine, jamais au dossier du README qui la porte. Une commande qui
suppose un `cd` préalable est à corriger.

## Dépannage impératif

Si un état a été créé impérativement en dépannage (ex. secret self-signed temporaire), il doit
être **remplacé par son équivalent GitOps** (SealedSecret, manifeste committé) puis supprimé du
cluster. Aucun état impératif ne doit survivre.
