# Donetick

Gestionnaire de tâches et de corvées auto-hébergé, déployé par Argo CD dans le namespace `donetick`.

## Déploiement

- Image amont : `donetick/donetick:v0.1.79`, épinglée au digest OCI.
- Stockage : SQLite dans le PVC RWO `data-donetick-0` (classe `openebs-lvm-thin`). Une seule réplique est intentionnelle.
- Accès : <https://donetick.lan.wittner.tech>, sur le listener interne `https-internal` du `shared-gw`.
- État : la base SQLite est persistante mais ne fait pas partie de Git ; la couvrir par Velero si sa conservation est requise.

## Secret requis avant synchronisation

`ExternalSecret` attend dans OpenBao KV v2 :

- chemin : `homelab/donetick/secrets`
- propriété : `jwt-secret`
- cible Kubernetes : Secret `donetick-env`, clé `DT_JWT_SECRET`

La valeur doit être aléatoire et comporter au moins 32 caractères. Elle signe les sessions : ne pas la changer sans nécessité ; toute rotation invalide les sessions et nécessite un redémarrage du StatefulSet pour être prise en compte.

Exemple opérateur (ne pas versionner la valeur) :

```bash
openssl rand -base64 48
bao kv put homelab/donetick/secrets jwt-secret='<valeur générée>'
```

Sans ce secret, le pod reste volontairement en `CreateContainerConfigError` plutôt que d'utiliser la clé JWT faible fournie par le fichier `selfhosted.yaml` de l'image.

## Vérification après synchronisation

```bash
kubectl -n donetick get externalsecret,statefulset,pod,pvc,svc,httproute
kubectl -n donetick get externalsecret donetick-env
kubectl -n donetick logs sts/donetick
```

La sonde `/health` est non authentifiée et vérifie que le processus est disponible. La création du premier compte local se fait dans l'interface ; l'inscription reste activée par défaut.
