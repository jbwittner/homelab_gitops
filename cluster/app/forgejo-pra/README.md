# forgejo-pra

## Rôle

La **machine d'exercice** du plan de reprise de la forge : une VM Debian jetable, éteinte par
défaut, sur laquelle on joue le protocole de
`homelab_emeriss/forgejo/doc/pra-exercices.md` sans toucher à la production.

> [!CAUTION]
> **Ce n'est PAS un standby, et ce composant ne raccourcit AUCUN RTO.** Rien ici ne prend le
> relais de la forge : la forge tourne en Docker sur une machine dédiée, hors du cluster, et c'est
> la condition qui empêche la dépendance circulaire ArgoCD → forge → ArgoCD (cf.
> [README racine](../../../README.md)). Une VM de reprise déclarée ici serait déployée par ArgoCD,
> qui lit son dépôt **sur la forge** : forge morte ⇒ pas de sync ⇒ pas de reprise. Ce composant
> sert **uniquement** à éprouver le plan, jamais à l'exécuter.

## Ce que ça achète

Le protocole actuel monte la pile parallèle **sur l'hôte de production**. Ses quatre coûts, et ce
que la VM en fait :

| Coût du protocole sur l'hôte | Dans la VM |
|---|---|
| Deux Forgejo + deux PostgreSQL sur les 2 Gio de plancher : l'OOM killer choisit sa victime, rien ne garantit que ce soit la copie | 4 vCPU / 4 Gio à part, aucune contention |
| `postgres-exporter` publie `9187` **en dur** ⇒ surcharge `profiles: ["jamais-en-exercice"]` obligatoire | ports propres, la surcharge devient inutile |
| Le `rm -rf` de l'étape 3 n'est séparé de la production que par le préfixe `pra-` | `/srv/forgejo` **n'existe pas** dans la VM |
| Fenêtres interdites : autour de 3h30 (timer de sauvegarde), et pendant qu'on pousse | l'exercice se joue n'importe quand |

Ce que ça **n'achète pas** : la VM démarre sur une Debian neuve, mais son cloud-init ne rejoue pas
`homelab_emeriss/doc/bootstrap-debian.md`. Le scénario 3 (perte totale de l'hôte) reste donc
**non éprouvé** par cet outil seul.

## Fichiers

- `forgejo-pra.app.yaml` — Application (archétype (c) : kustomize seul), wave par défaut.
- `manifests/namespace.yaml` — ns `forgejo-pra` labellisé **PSA `privileged`** (wave -1). Exigé
  par KubeVirt pour tout namespace portant des VM (d'où : pas de `CreateNamespace`).
- `manifests/virtualmachine.yaml` — la VM : `runStrategy: Halted`, disque importé depuis l'image
  cloud Debian par un `dataVolumeTemplate`, cloud-init inline. Le fichier porte le détail de
  chaque choix.
- `manifests/service.yaml` — Service LoadBalancer, IP **figée** dans le pool Cilium, `3001`→3000
  et `22`.

## Contraintes

- **La VM s'allume par un commit, pas par `virtctl start`.** `selfHeal: true` est actif :
  un démarrage impératif serait ré-`Halted` dans la minute. Passer `runStrategy` à `Always`,
  commiter, pousser. L'historique Git date ainsi chaque exercice — ce que le journal de
  `pra-exercices.md` demande de toute façon.
- **Éteinte entre deux exercices, et ce n'est pas de l'économie.** Une seconde forge laissée en
  marche porte **les mêmes identifiants de miroir poussé que la production** : `update_mirrors`
  passe 24 h après le démarrage du conteneur, et pousserait vers le dépôt GitHub — la copie de
  survie dont dépend toute reconstruction. Les surcharges `FORGEJO__mirror__ENABLED=false` et
  `FORGEJO__mailer__ENABLED=false` du protocole restent **obligatoires** ; la VM ne les remplace
  pas, elle ne fait que rendre l'oubli moins immédiatement destructeur.
- **Aucun secret dans ce composant, et ce dépôt est public.** Mot de passe `restic`, les sept
  `FORGEJO_*` et `DB_PASSWORD` se saisissent à la main dans la VM, **depuis les copies hors
  ligne** — c'est exactement ce que l'exercice complet annuel doit prouver. Une clé publique SSH
  n'est pas un secret.
- **L'IP `192.168.1.81` n'est déclarée nulle part ailleurs, et ne doit pas l'être.** Ni au reverse
  proxy `192.168.1.50`, ni au tunnel Cloudflare, ni dans le résolveur : c'est une copie de la forge
  avec ses vrais comptes. On s'y rend par l'IP. C'est pourquoi il n'y a pas d'`HTTPRoute` ici.
  ⚠️ Corollaire du protocole : `FORGEJO_DOMAIN` reste **inchangé** dans le `.env` d'exercice, donc
  Forgejo répond `404` à une requête portant un autre `Host`. L'accès par IP se fait avec l'en-tête :
  `curl -H 'Host: forgejo.wittner.tech' http://192.168.1.81:3001/api/healthz`.
- **VM éteinte = Service sans endpoint.** État normal, pas une panne.
- **L'image Debian est épinglée sur un build daté** et n'est suivie par aucun manager Renovate
  (`cloud.debian.org` n'est pas une datasource). Elle se rafraîchit à la main, à l'exercice
  complet annuel.

## Opérations

```bash
# --- Avant : la production doit être saine, sinon on diagnostique deux pannes à la fois
ssh <hôte-forge> sudo forgejo-ctl health

# --- Allumer : PAR GIT (cf. Contraintes)
sed -i '' 's/^  runStrategy: Halted/  runStrategy: Always/' \
  cluster/app/forgejo-pra/manifests/virtualmachine.yaml
git commit -am "exercice PRA: allumage de la VM" && git push
kubectl -n argocd get app forgejo-pra -w          # Synced/Healthy

# --- Suivre le démarrage. Le PREMIER allumage attend l'import de l'image (~10 min) :
kubectl -n forgejo-pra get dv forgejo-pra-root -w   # Phase: ImportInProgress → Succeeded
kubectl -n forgejo-pra get vmi forgejo-pra -w       # Running
virtctl -n forgejo-pra console forgejo-pra          # console série — cloud-init s'y déroule
ssh jbwittner@192.168.1.81                          # une fois cloud-init terminé

# --- Jouer le protocole : homelab_emeriss/forgejo/doc/pra-exercices.md § Protocole.
#     Les chemins /srv/pra-forgejo/{data,pgdata,restauration} sont déjà en place.
#     ⚠️ `compose.override.yaml` reste OBLIGATOIRE (mirror, mailer, cron, ROOT_URL, indexer).

# --- Éteindre : par Git, dans l'autre sens
sed -i '' 's/^  runStrategy: Always/  runStrategy: Halted/' \
  cluster/app/forgejo-pra/manifests/virtualmachine.yaml
git commit -am "exercice PRA: extinction" && git push

# --- Repartir d'un disque VIERGE (exercice complet annuel, ou VM salie).
#     Supprimer la VM emporte son DataVolume ; ArgoCD la recrée dans la minute, image réimportée.
#     Ce n'est pas de la dérive : c'est la même forme qu'un `delete pod` — l'état voulu est
#     dans Git, et selfHeal le rétablit.
kubectl -n forgejo-pra delete vm forgejo-pra
```
