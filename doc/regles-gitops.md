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

## Secrets

**Jamais** de `kubectl create secret`, jamais de Secret en clair dans Git.

### Un seul canal actif : sealed-secrets

> [!IMPORTANT]
> **Le second canal est mort.** Ce dépôt a eu deux canaux — sealed-secrets, et openbao via
> external-secrets. [openbao](../archive/openbao/README.md) est **archivé** et
> [external-secrets](../cluster/infra/external-secrets/README.md) est en `.noapp.yaml` : la CRD
> `ExternalSecret` n'existe plus dans le cluster. Les quatre `*.externalsecret.yaml` qui subsistent
> sont tous commentés dans leur `kustomization.yaml` et ne s'appliquent nulle part.
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

Onze fichiers, treize documents `SealedSecret` : `cloudflare-api-token`, `velero-gcs`,
`repo-homelab-gitops`, `argocd-oidc`, `argocd-notifications-secret`, `forgejo-admin`,
`forgejo-secrets`, `forgejo-smtp`, `forgejo-db-gcs`, `grafana-admin`, `alertmanager-smtp`,
`hermes-env`, `renovate-github`.

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
> 1. **La clé privée du contrôleur sealed-secrets.** Sans elle, les onze `SealedSecret` du repo
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
