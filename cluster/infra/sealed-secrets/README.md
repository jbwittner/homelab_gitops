# sealed-secrets

## Rôle

Contrôleur [Bitnami sealed-secrets](https://github.com/bitnami/sealed-secrets) : déchiffre dans
le cluster les `SealedSecret` committés dans Git. C'est le **seul** canal de secrets du repo —
règles : [doc/regles-gitops.md](../../../doc/regles-gitops.md). Il porte donc tout, y compris les
secrets les plus en amont du graphe de bootstrap : le credential SSH du dépôt privé
(`repo-homelab-gitops`, sans lequel ArgoCD ne clone rien) et le token DNS de
[cert-manager](../cert-manager/README.md) (wave `-5`). Wave **-8** : le contrôleur précède tout
SealedSecret consommé plus tard.

## Fichiers

- `sealed-secrets.app.yaml` — Application (archétype **(a)** : Helm + `$values`, depuis le
  2026-09-08). Contrôleur et namespace : `sealed-secrets`.
- `helm-values.yaml` — **un seul réglage**, `keyrenewperiod: "0"`, et c'est un réglage de plan de
  reprise, pas de fonctionnement. Voir §Contraintes.

⚠️ Le passage de l'archétype (d) à (a) donne à ce composant — en wave **-8**, le plus précoce —
une dépendance à la source **Git** pour son rendu. Ce n'est pas une nouvelle classe de dépendance
(l'Application vient déjà de Git par l'app-of-apps), mais c'est à savoir avant de diagnostiquer un
bootstrap à froid : un dépôt injoignable bloque désormais le contrôleur, donc **tous** les
`SealedSecret` en aval.

## Contraintes

> [!CAUTION]
> **La clé privée du contrôleur est le seul état non reconstructible du cluster.** Un contrôleur
> qui démarre sans clé restaurée en génère une **neuve** : tous les `SealedSecret` du repo
> deviennent indéchiffrables et chaque credential amont est à re-provisionner. En reconstruction,
> la clé se restaure **avant** le premier démarrage du contrôleur — étape 3 du
> [runbook](../../../doc/runbook-bootstrap.md).
>
> C'est aussi le **point de reprise unique de tout le homelab** : sans elle, le `SealedSecret`
> `velero-gcs` reste chiffré, velero ne lit pas son bucket, et **aucune** restauration n'est
> possible — y compris celle des `Secret` matérialisés dont dépend le reste. Cf.
> [`doc/forgejo-pra.md`](../../../doc/forgejo-pra.md) §4.

> [!CAUTION]
> **La rotation de la clé est COUPÉE (`keyrenewperiod: "0"`), et c'est ce qui rend la sauvegarde
> hors ligne suffisante.** Par défaut le contrôleur génère une nouvelle clé tous les 30 jours ;
> l'ancienne continue de déchiffrer, mais la nouvelle devient celle du **chiffrement**. Un
> `SealedSecret` scellé après une rotation est donc illisible avec une sauvegarde antérieure.
>
> ⚠️ **Et rien ne le signale.** En fonctionnement normal le contrôleur détient toutes ses clés et
> déchiffre tout : le parc paraît sain. L'écart n'apparaît qu'à la restauration sur un cluster
> neuf, sous la forme d'un `no key could decrypt secret` sur les scellés récents **et sur eux
> seuls**. Une sauvegarde partielle est plus dangereuse qu'une absence de sauvegarde : elle en a
> l'apparence.
>
> Ce qu'on perd en coupant est faible : **la rotation ne re-scelle pas les `SealedSecret`
> existants**, elle ne change que la clé des nouveaux. Sa valeur suppose qu'on re-scelle tout le
> parc à chaque tour, ce que personne ne fait ici.
>
> État au 2026-09-09 : une seule clé, `sealed-secrets-key7t2db`, créée le 2026-08-29 avec le
> cluster ; les `SealedSecret` du dépôt sont tous scellés avec elle — **11 fichiers, 13 documents**
> (un fichier peut en porter plusieurs, cf. `forgejo-admin.sealed.yaml`). La première rotation
> serait tombée vers le **2026-09-28** — ce réglage la supprime avant qu'elle n'ait lieu.
>
> Le compte se relit sans le tenir à jour à la main :
> `grep -rh 'kind: SealedSecret' cluster/ | wc -l`.

## Opérations

Commandes **depuis la racine du repo**.

### Sceller un Secret

```bash
# 1. Récupérer le cert public du contrôleur (une fois ; pub-cert.pem est gitignoré)
kubeseal --fetch-cert \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets \
  > pub-cert.pem

# 2. Template en clair (gitignoré) → SealedSecret, dans le manifests/ du composant consommateur
kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
  < cluster/<partie>/<name>/manifests/<secret>.secret.yaml \
  > cluster/<partie>/<name>/manifests/<secret>.sealed.yaml

# 3. Supprimer le clair, référencer le .sealed.yaml dans le kustomization.yaml, committer
rm cluster/<partie>/<name>/manifests/<secret>.secret.yaml
```

Le `SealedSecret` est chiffré **pour un couple (nom, namespace)** donné : le déplacer d'un
namespace à l'autre le rend indéchiffrable, il faut le resceller.

### Backup / restauration de la clé

```bash
# Backup — contient la clé privée : coffre, JAMAIS dans Git (motif .gitignore déjà en place).
# Le suffixe du nom de fichier est le cluster : une clé par contrôleur, et restaurer celle d'un
# autre cluster rend tous les SealedSecret indéchiffrables.
kubectl get secret -n sealed-secrets \
  -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealed-secrets-key-bleu-kalecgos.yaml

# Restauration (AVANT le démarrage du contrôleur), puis restart
kubectl apply -f sealed-secrets-key-bleu-kalecgos.yaml
kubectl rollout restart deployment/sealed-secrets -n sealed-secrets

# Quelle clé sert à sceller ? La PLUS RÉCENTE. Les autres restent utilisées au déchiffrement.
# ⚠️ Avec `keyrenewperiod: "0"` il ne doit y en avoir qu'UNE. Plusieurs lignes ici = la rotation a
#    repris (réglage retiré, ou chart changé), et la sauvegarde hors ligne n'est PLUS suffisante.
kubectl get secrets -n sealed-secrets \
  -l sealedsecrets.bitnami.com/sealed-secrets-key --sort-by=.metadata.creationTimestamp

# Contrôle de non-régression, à passer après tout bump du chart :
kubectl -n sealed-secrets get deploy sealed-secrets \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep -A1 key-renew
#   attendu : --key-renew-period puis "0"
```

⚠️ **La sauvegarde est un geste UNIQUE tant que la rotation est coupée.** Si `keyrenewperiod` est
un jour retiré, elle redevient périodique — et l'oubli sera invisible jusqu'à la reprise.

### Debug

```bash
kubectl get sealedsecrets -A
kubectl describe sealedsecret <name> -n <ns>     # events : « no key could decrypt secret » = mauvaise clé
kubectl logs -n sealed-secrets deploy/sealed-secrets
```
