# Donetick

Gestionnaire de tâches et de corvées auto-hébergé, déployé par Argo CD dans le namespace `donetick`.

## Déploiement

- Image amont : `donetick/donetick:v0.1.79`, épinglée au digest OCI.
- Stockage : SQLite dans le PVC RWO `data-donetick-0` (classe `openebs-lvm-thin`). Une seule réplique est intentionnelle.
- Accès : <https://donetick.lan.wittner.tech>, sur le listener interne `https-internal` du `shared-gw`.
- État : la base SQLite est persistante mais ne fait pas partie de Git. ⚠️ **Elle n'est
  sauvegardée par rien aujourd'hui** : [velero](../../infra/velero/README.md) est en `.noapp.yaml`
  et son unique périmètre déclaré est `hermes`. Donetick a exactement la même forme que lui
  (SQLite sur PVC, aucune chaîne native) et reste à arbitrer explicitement, cf. le commentaire
  `includedNamespaces` de son `helm-values.yaml`.

## Câblage du secret

> [!IMPORTANT]
> **Ce composant est INERTE tant que son `SealedSecret` n'est pas scellé et committé.** Les objets
> se déploient (ns, StatefulSet, Service, HTTPRoute) mais le pod reste en
> `CreateContainerConfigError` : `envFrom.secretRef` vise un Secret `donetick-env` qui n'existe
> pas encore. C'est l'échec VOULU, cf. plus bas.

Canal **sealed-secrets** (cf. [sealed-secrets](../../infra/sealed-secrets/README.md)), seul canal
de secrets actif du dépôt.

> [!NOTE]
> Le composant visait initialement **OpenBao via un `ExternalSecret`**. Ce canal n'a jamais pu
> fonctionner dans ce cluster : la CRD `ExternalSecret` n'est pas posée
> ([external-secrets](../../infra/external-secrets/README.md) est en `.noapp.yaml`) et le
> `ClusterSecretStore openbao` visé est archivé ([archive/openbao](../../../archive/openbao/README.md)).
> Laissé **actif** dans `kustomization.yaml`, il faisait échouer la sync de l'Application entière —
> donc aucun objet donetick n'était créé, et le composant n'est jamais monté. Corrigé le
> 2026-09-23 : le manifeste est désormais un vestige commenté, comme ceux de `cert-manager` et
> `kube-prometheus-stack`.

`DT_JWT_SECRET` signe les sessions. Valeur aléatoire, 32 caractères au minimum.

```bash
# 1. Partir du modèle versionné, remplir la valeur REMPLACER
cp cluster/app/donetick/manifests/donetick-env.secret.example.yaml \
   cluster/app/donetick/manifests/donetick-env.secret.yaml
openssl rand -base64 48

# 2. Sceller
kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
  < cluster/app/donetick/manifests/donetick-env.secret.yaml \
  > cluster/app/donetick/manifests/donetick-env.sealed.yaml

# 3. Jeter le clair (`*.secret.yaml` est gitignoré, mais il traîne sur le disque)
rm cluster/app/donetick/manifests/donetick-env.secret.yaml
```

⚠️ **Décommenter `- donetick-env.sealed.yaml` dans `manifests/kustomization.yaml` DANS LE MÊME
COMMIT.** Référencer un fichier absent fait échouer le rendu kustomize, donc le sync ArgoCD
entier — pas seulement ce Secret.

Le `SealedSecret` est chiffré pour le couple (`donetick-env`, `donetick`) : le renommer ou changer
son namespace exige de le resceller.

⚠️ **Ne jamais « débloquer » le pod en passant `envFrom.secretRef` en `optional: true`.** L'image
embarque un défaut dans son `config/selfhosted.yaml` amont —
`change_this_to_a_secure_random_string_32_characters_long`, valeur **publique et identique pour
toutes les instances** : quiconque la connaît peut forger un jeton de session valide. Le
`CreateContainerConfigError` est la protection, pas la panne.

Rotation : resceller, committer, puis **redémarrer à la main** — le fichier scellé n'entre dans
aucun `configMapGenerator` ici (le seul générateur est en `envs:`), donc le pod template ne bouge
pas et ArgoCD reste `Synced` sans rien relancer.

```bash
kubectl -n donetick rollout restart statefulset/donetick
```

## Vérification après synchronisation

```bash
kubectl -n donetick get statefulset,pod,pvc,svc,httproute
kubectl -n donetick get secret donetick-env    # produit par le contrôleur sealed-secrets
kubectl -n donetick logs sts/donetick
```

La sonde `/health` est non authentifiée et vérifie que le processus est disponible. La création du premier compte local se fait dans l'interface ; l'inscription reste activée par défaut.
