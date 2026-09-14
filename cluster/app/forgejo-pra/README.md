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

Et elle rend le **scénario 3** (perte totale de l'hôte) jouable pour la première fois : la VM part
d'une Debian neuve où **rien n'est installé**, donc l'exercice commence par jouer
`homelab_emeriss/doc/bootstrap-debian.md` pour de vrai. C'est le poste de temps que `pra.md`
désigne comme dominant, et que l'exercice sur l'hôte de production ne pouvait pas mesurer — l'hôte
était déjà bootstrappé.

## Fichiers

- `forgejo-pra.app.yaml` — Application (archétype (c) : kustomize seul), wave par défaut.
- `manifests/namespace.yaml` — ns `forgejo-pra` labellisé **PSA `privileged`** (wave -1). Exigé
  par KubeVirt pour tout namespace portant des VM (d'où : pas de `CreateNamespace`).
- `manifests/virtualmachine.yaml` — la VM : `runStrategy`, disque importé depuis l'image cloud
  Debian par un `dataVolumeTemplate`, cloud-init inline **réduit au §1 du bootstrap**. Le fichier
  porte le détail de chaque choix.
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
- **Le cloud-init ne fait que le §1 de `bootstrap-debian.md`** — compte, sudo, clé SSH — et
  **c'est délibéré**. Tout ce qu'on y pré-installerait serait autant que l'exercice ne mesure pas,
  or `pra.md` désigne le bootstrap comme le poste de temps dominant du scénario 3. Le §1 fait
  exception parce qu'il faut un chemin d'entrée : sans compte ni clé, la machine n'est joignable
  que par la console série et sans mot de passe.
  ⚠️ **Ne pas y rajouter de paquets « pour gagner du temps ».** Le temps gagné est exactement le
  temps qu'on voulait chronométrer.
- **Le `userData` inline plafonne à 2048 octets**, plafond dur du webhook
  `virtualmachine-validator.kubevirt.io`. Au-delà, le sync ArgoCD échoue sur
  `userdata exceeds 2048 byte limit. Should use UserDataSecretRef` — pas au démarrage de la VM,
  **à l'admission**. C'est pourquoi le bloc cloud-init ne porte aucun commentaire : ils comptent
  dans les 2048, et ils sont donc placés autour, dans le manifeste. Marge actuelle : ~600 octets.
  ⚠️ Passer par un `Secret` (`userDataSecretRef`) le jour où ça déborde est la porte de sortie
  upstream — mais ce cloud-init ne contient **aucun secret**, et un Secret non scellé dans un
  dépôt public est un mauvais signal. Élaguer avant d'en créer un.
- **Le DataVolume porte `cdi.kubevirt.io/storage.bind.immediate.requested`.**
  `openebs-lvm-thin` est en `WaitForFirstConsumer` et CDI honore ce mode : sans l'annotation, VM
  éteinte = aucun consommateur = PVC `Pending` et DataVolume `PendingPopulation` tant qu'on
  n'allume pas. Ce n'est **pas** une affaire de temps — l'import mesure 69 s (2026-09-14) et se
  ferait de toute façon au premier allumage. C'est une affaire de **lisibilité au repos** : sans
  l'annotation, l'état permanent du composant est indiscernable d'une panne de stockage ; avec,
  l'état nominal éteint est `DV Succeeded` + `PVC Bound`, et tout le reste est un vrai problème.
  ⚠️ Le prix : le PVC est provisionné sans savoir où la VM se schedulera, et le `nodeAffinity` du
  PV l'y cloue ensuite — ici `vert-ysondre`. Sans conséquence sur trois nœuds équivalents.
- **VM éteinte ⇒ l'Application est `Synced`/`Suspended`, jamais `Healthy`.** C'est le verdict
  d'ArgoCD pour une `VirtualMachine` en `runStrategy: Halted`, et c'est l'état NOMINAL entre deux
  exercices — pas un composant en panne. `Healthy` n'apparaît que pendant un exercice.
- **VM éteinte = Service sans endpoint.** État normal, pas une panne.
- **L'image Debian est épinglée sur un build daté** et n'est suivie par aucun manager Renovate
  (`cloud.debian.org` n'est pas une datasource). Elle se rafraîchit à la main, à l'exercice
  complet annuel.

## Prérequis dans la VM

> [!CAUTION]
> **Le cloud-init ne suffit PAS à lancer l'exercice.** Il pose la machine, pas la capacité à
> parler au bucket. Cinq gestes manuels restent entre le premier `ssh` et l'étape 1 du protocole,
> et `forgejo-ctl restore` s'arrête net sur chacun d'eux.

| # | Ce qui manque | Le symptôme si on l'oublie |
|---|---|---|
| 1 | **`sops`** | `sops absent — cf. §4 de doc/bootstrap-debian.md`. Debian ne l'empaquette pas ; c'est le binaire de la release GitHub, **somme de contrôle à vérifier**. ⚠️ C'est pour ça qu'il n'est PAS dans le cloud-init : l'automatiser ferait sauter le contrôle |
| 2 | **Clé `age`** en `/root/.config/sops/age/keys.txt` | `clé age introuvable ou illisible`. Prendre celle du **poste** — 2ᵉ destinataire de `homelab_emeriss/.sops.yaml` — pas celle de `vert-emeriss`. À effacer en fin d'exercice |
| 3 | **Le clone** en `/opt/homelab/homelab_emeriss` + `forgejo-ctl deploy` | `pile introuvable : /opt/homelab/homelab_emeriss/forgejo` — c'est le `STACK_DIR` par défaut de l'outil |
| 4 | **`/etc/forgejo/backup.env`** | `/etc/forgejo/backup.env introuvable ou illisible` |
| 5 | **`/etc/forgejo/restic-password`** | `le dépôt EXISTE mais ce mot de passe ne l'ouvre pas`. En exercice **complet**, il vient de la copie HORS LIGNE — c'est précisément ce qu'on éprouve |

⚠️ Aucun contournement pour 1 et 2 : `preparer_gcs()` est sur le chemin de **toute** invocation
`restic` de l'outil, et il n'accepte pas de clé GCS en clair.

Puis le `.env` d'exercice et le `compose.override.yaml` du § Protocole, qui restent **obligatoires**
— la VM ne les remplace pas.

## Ce que l'exercice prouve, et ce qu'il ne prouve pas

| Prouvé | Non prouvé |
|---|---|
| le snapshot est lisible ; archive et dump sont cohérents entre eux | **le RTO de la production** — voir l'avertissement ci-dessous |
| la séquence de restauration marche bout en bout | **scénario 3**, perte de l'hôte : le cloud-init court-circuite `bootstrap-debian.md`, or c'est le bootstrap qui est le poste de temps dominant |
| les sept `FORGEJO_*` et `DB_PASSWORD` s'accordent avec l'archive (donc les données sont déchiffrables) | **le délai de détection** : rien n'alerte, il n'a pas de borne, et il domine les deux RTO |
| que les copies **hors ligne** suffisent — à condition de partir d'elles | **scénarios 4 et 5** (bucket disparu, mot de passe `restic` perdu) : non testables par construction |
| la rotation de `SECRET_KEY` — **si** on la joue (exercice complet annuel) | Traefik, DNS, certificat (autre dépôt) ; le **registre de paquets**, jamais restauré |

> [!WARNING]
> **Le RTO mesuré ici est OPTIMISTE, et ne se reporte pas dans la table des RTO de `pra.md`.**
> 4 vCPU / 4 Gio sur du LVM de nœud, contre le plancher 2 Gio de l'hôte de production — et Git est
> IOPS-bound, pas débit-bound. Le chiffre va dans le journal de `pra-exercices.md` **avec la
> mention qu'il vient de la VM**. Les deux budgets de `pra.md` restent des raisonnements tant
> qu'un exercice n'a pas tourné sur la machine réelle.

## Opérations

```bash
# --- Avant : la production doit être saine, sinon on diagnostique deux pannes à la fois
ssh <hôte-forge> sudo forgejo-ctl health

# --- Allumer : PAR GIT (cf. Contraintes). Les deux valeurs sont cote a cote dans le manifeste,
#     l'une commentee : intervertir le `#`, commiter, pousser.
$EDITOR cluster/app/forgejo-pra/manifests/virtualmachine.yaml   # -> runStrategy: Always
git commit -am "exercice PRA: allumage de la VM" && git push
kubectl -n argocd get app forgejo-pra -w          # Synced/Healthy (Suspended tant qu'elle est éteinte)

# --- Suivre le démarrage. L'image est DÉJÀ importée (elle l'est au déploiement du composant,
#     pas à l'allumage — cf. l'annotation de liaison immédiate) : le DataVolume doit être
#     `Succeeded` AVANT qu'on allume. S'il est `PendingPopulation`, l'annotation a sauté.
kubectl -n forgejo-pra get dv forgejo-pra-root      # Phase: Succeeded
kubectl -n forgejo-pra get vmi forgejo-pra -w       # Running
virtctl -n forgejo-pra console forgejo-pra          # console série — cloud-init s'y déroule
ssh jbwittner@192.168.1.81                          # une fois cloud-init terminé

# --- Jouer le protocole : homelab_emeriss/forgejo/doc/pra-exercices.md § Protocole.
#     Les chemins /srv/pra-forgejo/{data,pgdata,restauration} sont déjà en place.
#     ⚠️ `compose.override.yaml` reste OBLIGATOIRE (mirror, mailer, cron, ROOT_URL, indexer).

# --- Éteindre : par Git, dans l'autre sens. ⚠️ NE PAS OUBLIER — une VM laissée en marche
#     finit par pousser vers le miroir GitHub (cf. Contraintes).
$EDITOR cluster/app/forgejo-pra/manifests/virtualmachine.yaml   # -> runStrategy: Halted
git commit -am "exercice PRA: extinction" && git push

# --- Repartir d'un disque VIERGE (exercice complet annuel, ou VM salie).
#     Supprimer la VM emporte son DataVolume ; ArgoCD la recrée dans la minute, image réimportée.
#     Ce n'est pas de la dérive : c'est la même forme qu'un `delete pod` — l'état voulu est
#     dans Git, et selfHeal le rétablit.
kubectl -n forgejo-pra delete vm forgejo-pra
```
