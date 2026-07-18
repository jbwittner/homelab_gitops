# homelab_gitops

Dépôt GitOps du homelab. Un cluster actif : **bleu-kalecgos** (Talos mono-nœud `vert-eranikus`),
piloté intégralement par **ArgoCD** en app-of-apps.

## Règle non négociable

> **Aucune donnée n'est poussée au cluster hors GitOps.** Toute ressource vit dans Git et est
> appliquée par ArgoCD. `kubectl` en écriture est réservé au bootstrap initial d'ArgoCD
> ([bleu-kalecgos/infra/argocd/README.md](bleu-kalecgos/infra/argocd/README.md)) et au debug
> read-only. Les secrets passent exclusivement par **SealedSecrets**
> ([bleu-kalecgos/infra/sealed-secrets/README.md](bleu-kalecgos/infra/sealed-secrets/README.md)).
> Détail des règles : [CLAUDE.md](CLAUDE.md).

## Structure

```
homelab_gitops/
├── bleu-kalecgos/            # cluster actif (app-of-apps)
│   ├── cluster.yaml          # TIER 1 — découvre les *.bootstrap.yaml
│   ├── infra/
│   │   ├── infra.bootstrap.yaml   # TIER 2 — découvre infra/**/*.app.yaml
│   │   └── <composant>/           # un dossier par composant infra
│   └── app/
│       ├── app.bootstrap.yaml     # TIER 2 — découvre app/**/*.app.yaml
│       └── <application>/         # un dossier par application
├── doc/
│   └── runbook-bootstrap-kalecgos.md   # runbook bootstrap/DR complet
└── archive/                  # anciens clusters, hors périmètre actif
```

Chaîne de découverte : `cluster.yaml` (glob `*.bootstrap.yaml`) → bootstraps infra/app
(glob `*.app.yaml`) → Applications. ⚠️ Le suffixe **exact** `.app.yaml` est requis, sinon le
composant n'est pas découvert.

## Conventions des composants

Chaque composant suit le même squelette :

```
<name>/
├── <name>.app.yaml       # Application ArgoCD — metadata.name == <name> == dossier
├── helm-values.yaml      # values Helm (si chart), référencées via $values (jamais inline)
├── README.md             # rôle, versions, opérations courantes
└── manifests/            # manifestes K8s bruts + kustomization.yaml (si nécessaires)
```

- **Nom** : `metadata.name` = nom du dossier = préfixe du fichier `.app.yaml`.
- **Labels** sur toute Application : `app.kubernetes.io/name`, `part-of: homelab-gitops`,
  `component`.
- **`targetRevision: main`** partout ; `releaseName` explicite sur toute source Helm.
- **Archétypes** :
  - **(a)** Helm + `$values` multi-source — `cert-manager`, `cnpg` ;
  - **(b)** = (a) + 3ᵉ source `manifests/` — `cilium`, `openebs` ;
  - **(c)** kustomize seul (`source.path` → `manifests/`) — `argocd`, `cert-manager-config`,
    `gateway-api`, `test-nginx` ;
  - **(d)** Helm sans values — `sealed-secrets` (migre vers (a) dès qu'une value est customisée).
- Pas de `CreateNamespace=true` quand `manifests/namespace.yaml` porte le namespace
  (nécessaire dès que le ns doit être labellisé, ex. PSA `privileged` pour openebs).

## Sync-waves

| Wave | Composant | Rôle |
|---|---|---|
| -10 | `gateway-api` | CRDs Gateway API + `shared-gw` |
| -8 | `sealed-secrets` | contrôleur de déchiffrement des secrets |
| -5 | `cert-manager` | émission TLS |
| -4 | `cert-manager-config` | ClusterIssuer Let's Encrypt + wildcards |
| -1 | `argocd` | self-management |
| 0 | `cilium`, `openebs`, apps | reste de la stack |

## Exposition réseau

Cilium **Gateway API** : `Gateway` partagé `shared-gw` (ns `gateway`, classe `cilium`,
LB `192.168.1.80` via `CiliumLoadBalancerIPPool` + L2 announce). Exposer un service = créer un
`HTTPRoute` avec `parentRef` → `shared-gw` + `sectionName` du listener. TLS terminé au Gateway
(secrets `wildcard-*-tls` scellés, émis par cert-manager).

## Bootstrap / disaster recovery

Procédure complète : [doc/runbook-bootstrap-kalecgos.md](doc/runbook-bootstrap-kalecgos.md).
Trois gestes manuels irréductibles : `kubectl apply -k bleu-kalecgos/infra/argocd/manifests`,
restauration de la clé sealed-secrets, restart one-shot de `cilium-operator`. Tout le reste
converge par sync-waves après `kubectl apply -f bleu-kalecgos/cluster.yaml`.
