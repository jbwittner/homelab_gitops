# external-secrets

> [!IMPORTANT]
> **Composant DÉSACTIVÉ et vidé de sa substance.**
>
> - Le fichier est `external-secrets.noapp.yaml` : le glob `{*.app.yaml,*.appset.yaml}` de
>   [`infra.bootstrap.yaml`](../infra.bootstrap.yaml) ne le ramasse pas. **Rien n'est déployé** —
>   `kubectl -n argocd get app external-secrets` ne rend rien.
> - Le backend de secrets qui l'alimentait a été **retiré du dépôt**, et son `ClusterSecretStore`
>   avec lui. Il ne reste ici qu'un `Namespace` et des values Helm.
> - Il n'existe **aucun `ExternalSecret` actif** dans le dépôt. Les quatre fichiers qui subsistent
>   (`cloudflare-api-token`, `grafana-oidc`, `grafana-admin`, `alertmanager-smtp`) sont tous
>   commentés dans leur `kustomization.yaml`.
>
> **Le seul canal de secrets actif est [sealed-secrets](../sealed-secrets/README.md)** — cf.
> [`doc/regles-gitops.md`](../../../doc/regles-gitops.md).

## Rôle

External Secrets Operator (ESO) : lit des secrets dans un backend externe et les matérialise en
`Secret` Kubernetes natifs, que les composants consomment sans rien savoir de leur origine.

Le composant est conservé **désactivé** plutôt que supprimé parce que la question qu'il tranche
reste ouverte : à partir d'un certain nombre de secrets, un backend externe rend la **rotation**
possible sans commit ni `kubeseal`. C'est le seul avantage réel qu'il avait sur sealed-secrets, et
la seule raison de le remonter un jour.

## Fichiers

- `external-secrets.noapp.yaml` — `Application`, wave `-7`, destination `bleu-kalecgos`.
  **Extension `.noapp.yaml` : non déployé.** La remettre à `.app.yaml` est le geste d'activation
- `helm-values.yaml` — CRDs par le chart, RBAC `serviceaccounts/token`, cache de tokens,
  ServiceMonitor
- `manifests/namespace.yaml` — ns `external-secrets` (wave -1), sans label PodSecurity
- `manifests/kustomization.yaml` — le namespace seul, sans champ `namespace:` (ressource
  cluster-scoped)

## Remonter un backend de secrets

Quatre gestes, dans cet ordre — aucun n'est fait aujourd'hui :

1. **Déployer un backend** et le rendre joignable depuis le cluster.
2. **Écrire un `ClusterSecretStore`** dans `manifests/`, et le référencer dans le
   `kustomization.yaml`. ⚠️ **Le garder cluster-scoped** : c'est ce qui permet à un `ExternalSecret`
   de n'importe quel namespace de le viser sans le redéclarer.
3. **Renommer `external-secrets.noapp.yaml` en `.app.yaml`.** La wave `-7` place le contrôleur
   avant le premier `ExternalSecret` consommé.
4. **Décommenter les `*.externalsecret.yaml`** un par un, dans le même commit que la valeur posée
   côté backend.

⚠️ **Le nom du store est structurant** : les `ExternalSecret` des composants le référencent par
nom. Changer ce nom oblige à rouvrir chacun d'eux.

## Contraintes

- **`deletionPolicy: Retain` sur tout `ExternalSecret`.** Un backend indisponible ne doit pas
  faire disparaître les `Secret` déjà livrés — sans quoi une panne du backend devient une panne de
  toutes les charges qui en dépendent. C'est la contrainte qui a le plus coûté à apprendre, et
  elle vaut pour n'importe quel backend futur.
- **Un `ExternalSecret` ne va jamais dans un dossier servant à l'`apply -k` d'amorçage.** À
  l'étape 2 du [bootstrap](../../../doc/runbook-bootstrap.md), la CRD n'existe pas encore : le
  `kustomize build` échouerait sur `no matches for kind`.
- **La CRD est posée par le chart** (`installCRDs`). Tant que ce composant est en `.noapp.yaml`,
  `kind: ExternalSecret` est **inconnu du cluster** : un manifeste décommenté par erreur met
  l'Application qui le porte en `ComparisonError`, pas en simple avertissement.
- **La configuration du backend ne vit pas dans ce repo.** Elle relève de l'outil qui le
  provisionne. Rien ici ne la vérifie : la seule preuve que les deux s'accordent est un
  `ExternalSecret` qui passe `SecretSynced`.

## Opérations

Sans composant déployé, il n'y a rien à diagnostiquer. Les commandes utiles le jour d'une remise en
service :

```bash
kubectl -n argocd get app external-secrets           # existe seulement si renommé en .app.yaml
kubectl get clustersecretstore                        # Ready=True attendu
kubectl get externalsecrets -A                        # STATUS=SecretSynced attendu
kubectl -n external-secrets logs deploy/external-secrets
```

Un `ExternalSecret` en échec porte sa cause dans ses conditions
(`kubectl describe externalsecret <nom> -n <ns>`) : store non `Ready`, droits manquants côté
backend, ou chemin inexistant. Forcer une resynchronisation :

```bash
kubectl annotate externalsecret <nom> -n <ns> force-sync=$(date +%s) --overwrite
```

- **Upgrade** : bumper `targetRevision` dans `external-secrets.noapp.yaml`. Les CRDs sont livrées
  par le chart, donc mises à jour avec lui.
