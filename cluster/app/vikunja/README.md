# vikunja

## Rôle

Vikunja est le gestionnaire de tâches personnel du homelab. L'application utilise le chart
amont et une base PostgreSQL mono-instance gérée par CloudNativePG.

## Fichiers

- `vikunja.app.yaml` — Application Argo CD (chart Helm, values et manifestes métier).
- `helm-values.yaml` — configuration du chart, connexion à la base CNPG et stockage des pièces jointes.
- `manifests/vikunja-db.yaml` — Cluster PostgreSQL CNPG ; il dérive `vikunja-db-rw` et `vikunja-db-app`.
- `manifests/vikunja-httproute.yaml` — exposition interne sur `vikunja.lan.wittner.tech`.

## Contraintes

- L'instance est seulement accessible sur le listener interne `https-internal`; le reverse proxy LAN doit aussi connaître `vikunja.lan.wittner.tech`.
- L'inscription est ouverte uniquement pour le test et doit être désactivée avant un usage durable.
- Cette première version ne configure volontairement aucune sauvegarde CNPG. Les données et sessions ne sont donc pas récupérables après une perte de volume. Ajouter le plugin barman-cloud, un ObjectStore et une ScheduledBackup avant tout usage durable.
- Sans `service.secret` scellé, Vikunja génère sa clé de signature au démarrage : un redémarrage invalide les sessions existantes. Ajouter un SealedSecret avant une mise en service durable.

## Opérations

```bash
kubectl -n vikunja get cluster vikunja-db
kubectl -n vikunja get pods,svc,httproute
```
