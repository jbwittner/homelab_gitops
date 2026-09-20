# Exposition réseau

## Architecture

Cilium implémente **Gateway API**. Le `Gateway` partagé unique est **`shared-gw`** (ns `gateway`,
classe `cilium`), défini dans
[`cluster/infra/gateway-api/manifests/gateway.yaml`](../cluster/infra/gateway-api/manifests/gateway.yaml).
Exposer un service = un `HTTPRoute` qui s'y attache.

- **LB** : une IP allouée par le `CiliumLoadBalancerIPPool` `bleu-kalecgos-pool`
  (`192.168.1.80-89`, [`ip-pool.yaml`](../cluster/infra/cilium/manifests/ip-pool.yaml)) et annoncée
  en **L2** (`bleu-kalecgos-l2`, `loadBalancerIPs: true`). En pratique `shared-gw` prend
  **`192.168.1.80`**.
  ⚠️ **Une seconde IP du pool est prise, et elle n'a aucun hostname** : `192.168.1.81`, figée par
  annotation `lbipam.cilium.io/ips` sur le Service de
  [forgejo-pra](../cluster/app/forgejo-pra/README.md). C'est **délibérément** le seul service du
  cluster joignable par IP nue : c'est une copie d'exercice de la forge, avec ses vrais comptes,
  et lui donner un nom serait le premier pas vers sa déclaration au proxy. Elle ne répond que
  VM allumée, c'est-à-dire pendant un exercice.
- **TLS terminé au Gateway** : secrets `wildcard-public-tls` et `wildcard-lan-tls` (ns `gateway`),
  émis par cert-manager (Let's Encrypt DNS-01 Cloudflare,
  [`certificates.yaml`](../cluster/infra/cert-manager/manifests/certificates.yaml)) et référencés en
  `Terminate` par les listeners. Les backends sont joints en **HTTP clair**.
- La `GatewayClass cilium` est **auto-créée par le contrôleur Cilium** — ne pas la déclarer.

> [!NOTE]
> **Mono-cluster.** `gateway-api` et `cilium` sont des `Application` (destination `bleu-kalecgos`),
> pas des `ApplicationSet` : `shared-gw` n'existe que sur ce cluster. Le préfixe
> `bleu-kalecgos-` des objets Cilium (`namePrefix` du kustomize) est le vestige d'un découpage
> multi-cluster qui n'a jamais eu de second membre — il est conservé parce que le renommer
> obligerait à reprendre les `ignoreDifferences`, pas parce qu'un spoke existe.

## Listeners (HTTPS :443)

Les **deux** listeners de `shared-gw`, tous deux en `allowedRoutes.namespaces.from: All` :

| `sectionName` | Hostname | Secret TLS | Usage |
|---|---|---|---|
| `https-public` | `*.wittner.tech` | `wildcard-public-tls` | services exposés publiquement |
| `https-internal` | `*.lan.wittner.tech` | `wildcard-lan-tls` | services internes (LAN uniquement) |

⚠️ Un wildcard ne couvre qu'**un** niveau. La règle vaut pour le certificat, le listener **et**
l'enregistrement DNS : `grafana.lan.wittner.tech` est couvert, `a.b.lan.wittner.tech` ne l'est pas.

## Exposé aujourd'hui

| Hostname | Listener | Composant |
|---|---|---|
| `argocd.lan.wittner.tech` | `https-internal` | [argocd](../cluster/infra/argocd/README.md) |
| `grafana.lan.wittner.tech` | `https-internal` | [kube-prometheus-stack](../cluster/app/kube-prometheus-stack/README.md) |
| `alertmanager.lan.wittner.tech` | `https-internal` | [kube-prometheus-stack](../cluster/app/kube-prometheus-stack/README.md) |
| `hermes.lan.wittner.tech` | `https-internal` | [hermes](../cluster/app/hermes/README.md) — dashboard (9119) |
| `hermes-api.lan.wittner.tech` | `https-internal` | [hermes](../cluster/app/hermes/README.md) — API (8642) |

⚠️ **`argocd.lan.wittner.tech` n'est pas qu'une UI** : `/api/webhook` y reçoit le webhook « push »
de la forge, qui déclenche la sync immédiate au lieu du polling de 3 min
([argocd §Webhook Forgejo](../cluster/infra/argocd/README.md)). C'est donc un flux **entrant**
depuis la machine Docker de la forge, par le même proxy et la même `HTTPRoute` que l'UI — rien à
ajouter côté réseau, mais deux couplages hors dépôt de plus : le webhook lui-même et
`FORGEJO__webhook__ALLOWED_HOST_LIST`, qui doit nommer ce hostname (`external` seul le refuse,
l'adresse étant privée).

⚠️ **Plus aucun service de ce cluster n'est public depuis le 2026-09-11**, et le listener
`https-public` n'a plus aucune route : Forgejo était le seul, il tourne maintenant en Docker sur
une machine dédiée ([archive/forgejo](../archive/forgejo/README.md)). Le listener reste déclaré —
le certificat wildcard `*.wittner.tech` est émis et renouvelé pour lui — mais il ne sert plus rien.

Non exposés volontairement : Prometheus (port-forward), Loki (API sans authentification, jointe
uniquement en intra-cluster).

**Deux hostnames servis AILLEURS que par ce cluster**, à ne pas chercher dans un `HTTPRoute` :

| Hostname | Servi par | Vu d'ici comme |
|---|---|---|
| `forgejo.wittner.tech` | machine Docker, via tunnel Cloudflare puis proxy `192.168.1.50` | la source du GitOps que lit `argocd-repo-server` |
| `forgejo-metrics.lan.wittner.tech` | même machine, publiée sur le LAN par le proxy `192.168.1.50` | cible `job="forgejo"` de [forgejo-monitoring](../cluster/app/forgejo-monitoring/README.md) |
| `node-exporter-emeriss.lan.wittner.tech` | même machine, pile `node-exporter/` de `homelab_emeriss` | cible `job="external-node"` de [hosts-monitoring](../cluster/app/hosts-monitoring/README.md) — la machine, **et le transport des métriques de sauvegarde** |
| `forgejo-db-metrics.lan.wittner.tech` | même machine, service `postgres-exporter` de la pile `forgejo/` | cible `job="forgejo-db"` de forgejo-monitoring — la base |

⚠️ Les quatre dépendent du reverse proxy et d'aucun objet de ce dépôt. Les trois derniers sont en
`*.lan.wittner.tech` : ils tombent donc sous la règle ci-dessous — non déclarés au proxy, ils
répondent **404**, et le symptôme dans le cluster est une cible Prometheus en erreur, pas une
alerte de réseau.

⚠️ **Trois hostnames sur UNE SEULE machine, répartis sur DEUX composants du cluster.** Ce n'est pas
un doublon : `node-exporter-emeriss` appartient à `hosts-monitoring` (la machine, qui survit à ce
qu'elle héberge), les deux autres à `forgejo-monitoring` (la forge et sa base, qui meurent
ensemble). Le découpage suit le cycle de vie, pas la topologie.

⚠️ **Le nom `node-exporter-emeriss` porte celui de la MACHINE, pas seulement du service**, et c'est
délibéré : la pile d'en face est duplicable sur un autre hôte, et un nom générique ferait collision
au premier second exportateur — côté proxy comme côté résolveur, le second écrasant le premier en
silence. Les deux autres n'ont pas ce besoin : la forge est un singleton.

⚠️ **Deux copies de référence des règles Traefik dans `homelab_emeriss`, et aucune n'est celle qui
sert** — `forgejo/traefik/forgejo.yml` (routers `forgejo`, `forgejo-metrics`, `forgejo-db-metrics`)
et `node-exporter/traefik/node-exporter-emeriss.yml`. Le fichier réellement lu vit dans
`homelab_proxmox/pve-ysera/traefik/dynamic/`, monté en lecture seule sur `/etc/traefik-git` du
CT 201. Rien ne synchronise les deux côtés.

⚠️ **Elles ont déjà divergé dans les DEUX sens**, ce qui est le mode de panne à connaître :
`forgejo-metrics` existait côté servi sans avoir jamais été recopié dans `homelab_emeriss` ;
`forgejo-db-metrics` et `node-exporter-emeriss` ont été écrits dans `homelab_emeriss` sans exister
côté servi. **Constaté le 2026-09-11** : les deux cibles Prometheus correspondantes répondaient
`404`, alors que les exportateurs tournaient et que les Secrets étaient bons. Un 404 sur une cible
désigne le reverse proxy, jamais le cluster.

## DNS et reverse proxy

> [!IMPORTANT]
> **Tout hostname `*.lan.wittner.tech` doit être déclaré au reverse proxy du LAN
> (`192.168.1.50`).** Ce n'est pas optionnel et ce n'est pas du DNS : un `HTTPRoute` parfaitement
> sain, `Accepted`/`ResolvedRefs=True`, répond **404** tant que le nom n'y figure pas. C'est le
> premier réflexe quand un service fraîchement exposé ne répond pas, avant de suspecter le Gateway.

Le résolveur du réseau doit renvoyer `*.lan.wittner.tech` vers l'IP du LB, `192.168.1.80`. Si le
résolveur porte des entrées nominatives plutôt qu'un vrai wildcard, chaque nouveau nom est à créer
à la main.

Les zones `*.lan` ne sont **jamais** publiées chez Cloudflare : seul le TXT `_acme-challenge` du
DNS-01 y transite, ce qui suffit à émettre un certificat Let's Encrypt pour un nom qui n'est pas
joignable depuis Internet.

## Chemin d'entrée public

⚠️ **Il n'aboutit plus dans ce cluster.** `forgejo.wittner.tech` passe par un **tunnel Cloudflare**
puis un routeur Traefik (`192.168.1.50`) — et depuis le 2026-09-11 le proxy le renvoie sur la
machine Docker de la forge, plus sur `shared-gw`. Ces couplages ne sont vérifiables par aucun
manifeste d'ici ; le raisonnement d'origine est conservé dans
[archive/forgejo](../archive/forgejo/README.md) §Points de couplage hors dépôt.

Conséquence pour ce dépôt : le chemin d'entrée public est **libre**. Exposer un service sur
`https-public` demande donc, en plus de l'`HTTPRoute`, une route côté tunnel et côté proxy — rien
n'en reste de préconfiguré.

## Exposer un service

Créer un `HTTPRoute` dans le `manifests/` du composant :

- `parentRefs` → `shared-gw` (ns `gateway`) + `sectionName` du listener adapté ;
- `group`/`kind`/`weight` et le `matches` **explicites** — plus obligatoires depuis que le
  server-side diff est actif (`controller.diff.server.side` dans
  [argocd](../cluster/infra/argocd/README.md), qui absorbe les defaults injectés par le CRD),
  mais gardés dans le modèle : ils documentent ce qui est réellement appliqué ;
- backend en **HTTP clair** (le TLS est terminé au Gateway) ;
- puis, pour un nom en `.lan`, **le déclarer au reverse proxy `192.168.1.50`**.

Modèle de référence :
[`grafana-httproute.yaml`](../cluster/app/kube-prometheus-stack/manifests/grafana-httproute.yaml).

## Vérifier

```bash
kubectl -n gateway get gateway shared-gw     # PROGRAMMED=True, adresse 192.168.1.80
kubectl -n gateway get certificate           # les 2 wildcards READY=True
kubectl get httproute -A                     # Accepted / ResolvedRefs
```

Un listener en `ResolvedRefs=False` = son secret TLS manque (certificat pas encore émis).
Le header de réponse `server: envoy` confirme que le trafic passe bien par le proxy Cilium.
Un **404** malgré tout ce qui précède au vert = le nom manque au reverse proxy.
