# OpenBao — contrat Terraform

Ce que le **repo Terraform** doit poser dans le coffre pour que les clusters puissent lire leurs
secrets. Ce dépôt-ci déclare les *consommateurs*
([external-secrets](../cluster/infra/external-secrets/README.md)) ; il ne configure **rien**
dans openbao et ne vérifie rien. La seule preuve que les deux s'accordent est l'état `Ready`
des `ExternalSecret`.

Mécanisme et vocabulaire : [secrets.md](secrets.md). Règles de répartition des secrets entre
canaux : [regles-gitops.md](regles-gitops.md).

## Vue d'ensemble

| Objet openbao | Combien | Pourquoi |
|---|---|---|
| Secrets engine **KV v2** sur `kv` | **1**, partagé | le coffre est unique, il vit sur le hub et ne dépend d'aucun cluster |
| Auth method **`kubernetes-<cluster>`** | **1 par cluster** | une méthode d'auth est liée à **un** API server (host, CA, TokenReview) |
| **Policy** `external-secrets` | **1**, partagée | tous les clusters lisent la même arborescence `kv/homelab/*` |
| **Role** `external-secrets` | **1 par mount d'auth** | un rôle appartient à son mount, il ne se partage pas |
| Auth method **`oidc`** (authentik) | **1** | le login **humain** ; il ne dépend d'aucun cluster, seulement d'authentik |
| **Policy** `openbao-admin` + groupe externe | **1** | mappe le groupe authentik `app-openbao-admin` sur des droits dans le coffre |

Les quatre premières lignes servent les **machines** (external-secrets), les deux dernières
l'**humain** (§5). Les deux jeux sont indépendants : casser l'OIDC ne coupe pas les
`ExternalSecret`, et réciproquement.

> [!IMPORTANT]
> **Les valeurs des secrets ne passent JAMAIS par Terraform.** Elles finiraient en clair dans le
> state, ce qui reproduit exactement le problème qu'on cherche à éviter. Terraform pose la
> **structure** (engine, auth, policy, roles) ; les valeurs se posent au coffre à la main, par
> `bao kv put` — cf. [runbook-bootstrap.md](runbook-bootstrap.md), étape 8b.

## Prérequis

- OpenBao déployé et **descellé** ([cluster/infra/openbao](../cluster/infra/openbao/README.md)) ;
- Terraform authentifié auprès de lui — via `BAO_ADDR`/`VAULT_ADDR` sur
  `https://openbao.lan.wittner.tech` et un token. Le token root convient pour l'amorçage, mais
  n'a rien à faire dans un CI : prévoir un AppRole dédié ensuite ;
- il n'existe pas de provider Terraform officiel `openbao` publié à ce jour ; le provider
  **`hashicorp/vault`** fonctionne contre OpenBao, dont l'API est compatible.

```hcl
terraform {
  required_providers {
    vault = { source = "hashicorp/vault", version = "~> 4.0" }
  }
}

provider "vault" {
  address = "https://openbao.lan.wittner.tech"
  # token via la variable d'environnement VAULT_TOKEN — jamais en dur ici
}
```

## 1. Le secrets engine

Un seul, partagé par tous les clusters.

```hcl
resource "vault_mount" "kv" {
  path        = "kv"
  type        = "kv"
  options     = { version = "2" }
  description = "Secrets du homelab, consommés par external-secrets"
}
```

⚠️ Dans l'UI, `Secrets → Enable new engine` propose une entrée **`kubernetes`** : ce n'est
**pas** ça. C'est le *Kubernetes secrets engine*, qui fabrique des ServiceAccounts éphémères —
l'inverse de la méthode d'auth du même nom. Prendre **KV**, version **2**.

## 2. Les méthodes d'auth, une par cluster

Déclarer les clusters une fois, le reste se dérive. Ajouter un cluster = ajouter une entrée.

```hcl
variable "clusters" {
  description = "Clusters autorisés à lire le coffre. La clé est le nom du cluster."
  type = map(object({
    kubernetes_host    = string
    kubernetes_ca_cert = optional(string)   # spoke uniquement
    token_reviewer_jwt = optional(string)   # spoke uniquement, sensible
  }))
}

# Exemple de valeurs — le hub n'a besoin de rien d'autre que son host interne.
#
#   clusters = {
#     bleu-kalecgos  = { kubernetes_host = "https://kubernetes.default.svc.cluster.local:443" }
#     bleu-arcanagos = {
#       kubernetes_host    = "https://192.168.1.12:6443"
#       kubernetes_ca_cert = file("…")
#       token_reviewer_jwt = "…"
#     }
#   }

resource "vault_auth_backend" "k8s" {
  for_each = var.clusters
  type     = "kubernetes"
  # ⚠️ Ce path DOIT matcher le `mountPath` du ClusterSecretStore du cluster, dans
  # cluster/infra/external-secrets/<cluster>/manifests/clustersecretstore-openbao.yaml
  path     = "kubernetes-${each.key}"
}

resource "vault_kubernetes_auth_backend_config" "k8s" {
  for_each = var.clusters
  backend  = vault_auth_backend.k8s[each.key].path

  kubernetes_host    = each.value.kubernetes_host
  kubernetes_ca_cert = each.value.kubernetes_ca_cert
  token_reviewer_jwt = each.value.token_reviewer_jwt

  # Sur le HUB, openbao tourne dans le cluster : il valide les tokens avec le CA et le
  # ServiceAccount du pod (le chart active `server.authDelegator`, qui lui donne
  # `system:auth-delegator`). Rien d'autre à fournir.
  #
  # Sur un SPOKE, openbao n'a aucun accès local à l'API TokenReview : il faut désigner
  # explicitement l'API server, son CA, et une identité habilitée à faire la TokenReview.
  disable_local_ca_jwt = each.value.token_reviewer_jwt != null
}
```

### Le `token_reviewer_jwt` d'un spoke

C'est un credential **du cluster distant**, pas du coffre. Il exige, **dans ce dépôt-ci**, un
`ServiceAccount` du spoke lié à `system:auth-delegator` et un `Secret` de type
`kubernetes.io/service-account-token` pour obtenir un JWT non expirant — exactement le motif
déjà employé par [argocd-manager](../cluster/infra/argocd-manager/README.md) pour l'identité du
hub.

> [!WARNING]
> **Ces manifestes n'existent pas encore** sous
> `cluster/infra/external-secrets/bleu-arcanagos/manifests/`. Tant qu'ils ne sont pas posés, le
> mount du spoke ne peut pas être configuré et seul le hub lit le coffre.

Le récupérer sans le faire transiter par un fichier, une fois les manifestes en place :

```bash
kubectl --context bleu-arcanagos -n external-secrets \
  get secret openbao-token-reviewer -o jsonpath='{.data.token}' | base64 -d
```

⚠️ Valeur **sensible** : ne pas la committer en `.tfvars`. La passer par une variable
d'environnement `TF_VAR_…`, ou la lire directement avec le provider `kubernetes` pour qu'elle ne
touche jamais un fichier.

## 3. La policy

Une seule, partagée. Lecture seule sur l'arborescence du homelab.

```hcl
resource "vault_policy" "external_secrets" {
  name = "external-secrets"

  # KV v2 : la donnée est sous /data/, ses versions sous /metadata/.
  # `read` sur metadata sert aux ExternalSecret qui demandent `metadataPolicy: Fetch` ;
  # `list` n'est utile qu'à l'exploration manuelle — retirable si tu veux serrer.
  policy = <<-EOT
    path "kv/data/homelab/*" {
      capabilities = ["read"]
    }
    path "kv/metadata/homelab/*" {
      capabilities = ["read", "list"]
    }
  EOT
}
```

Le jour où un spoke ne doit voir qu'un sous-arbre, écrire une seconde policy
(`kv/data/homelab/arcanagos/*`) et l'attacher à **son** rôle. Le stockage, lui, ne bouge pas.

## 4. Les rôles

Un par mount d'auth, tous identiques.

```hcl
resource "vault_kubernetes_auth_backend_role" "external_secrets" {
  for_each = var.clusters
  backend   = vault_auth_backend.k8s[each.key].path
  role_name = "external-secrets"

  # Le ServiceAccount d'ESO, tel que le pose le chart (`serviceAccount.name` dans
  # cluster/infra/external-secrets/common/helm-values.yaml).
  bound_service_account_names      = ["external-secrets"]
  bound_service_account_namespaces = ["external-secrets"]

  token_policies = [vault_policy.external_secrets.name]
  token_ttl      = 3600

  # ⚠️ `audience` volontairement ABSENT. ESO demande un token portant l'audience par défaut de
  # l'API server ; en fixer une ici sans ajouter `serviceAccountRef.audiences` dans le
  # ClusterSecretStore produit un `403 permission denied` au login.
}
```

## 5. L'auth OIDC — se connecter en tant qu'humain

Tout ce qui précède sert les **machines**. Pour ouvrir l'UI `https://openbao.lan.wittner.tech`
ou lancer un `bao kv put` sans coller le token root, il faut un mount **`oidc`** adossé à
authentik — le même fournisseur d'identité que
[argocd](../cluster/infra/argocd/README.md) et
[grafana](../cluster/app/kube-prometheus-stack/README.md), avec la même convention de groupe.

> [!IMPORTANT]
> **Le token root reste le break-glass, et il ne se supprime pas.** L'OIDC ajoute un chemin de
> connexion, il n'en retire aucun. Si authentik est en panne — ou si sa propre base est
> inaccessible parce que son `secret-key` vient justement du coffre — le token root est le seul
> moyen d'entrer. Même raisonnement que le login local conservé sur Grafana.

### 5.1 Côté authentik (même repo Terraform, provider `authentik`)

Un Provider OAuth2/OIDC **confidentiel** + son Application, exactement comme pour argocd :

| Contrat | Valeur |
|---|---|
| `client_id` | `openbao` |
| Type de client | **confidential** (le coffre garde son `client_secret`) |
| Issuer | `https://authentik.wittner.tech/application/o/openbao/` |
| Scopes | `openid`, `profile`, `email`, **`groups`** |
| Groupe d'admin | **`app-openbao-admin`** (convention `app-<composant>-admin`) |
| Redirect URIs | les deux ci-dessous, en `strict` |

```
https://openbao.lan.wittner.tech/ui/vault/auth/oidc/oidc/callback   # login par l'UI
http://localhost:8250/oidc/callback                                 # login par la CLI `bao`
```

⚠️ **Le chemin `/ui/vault/…` n'est pas une faute de frappe** : l'UI d'OpenBao est un fork de
celle de Vault et a gardé le segment `vault` dans ses routes. Si le login échoue en
`redirect_uri_error`, la valeur exacte refusée est lisible dans **Events → Logs** d'authentik :
c'est elle qu'il faut inscrire, pas celle devinée ici. Le second URI n'est pas optionnel dès
qu'on veut la CLI : `bao login -method=oidc` ouvre un listener local sur le port 8250.

### 5.2 Le mount et son rôle

```hcl
resource "vault_jwt_auth_backend" "oidc" {
  type = "oidc"
  path = "oidc"                       # ⚠️ se retrouve DEUX fois dans l'URI de callback de l'UI

  oidc_discovery_url = "https://authentik.wittner.tech/application/o/openbao/"
  oidc_client_id     = "openbao"
  oidc_client_secret = var.openbao_oidc_client_secret   # sensible, cf. encadré plus bas

  # Sans ça, l'UI n'affiche pas « OIDC » dans son menu déroulant de méthodes : le mount existe,
  # mais il faut le taper à la main. `unauth` n'expose que son NOM à un visiteur non connecté.
  tune {
    listing_visibility = "unauth"
  }

  # Le rôle employé quand l'UI ou la CLI n'en précise aucun — c'est le cas nominal.
  default_role = "default"
}

resource "vault_jwt_auth_backend_role" "default" {
  backend   = vault_jwt_auth_backend.oidc.path
  role_name = "default"
  role_type = "oidc"

  user_claim   = "sub"        # identifiant stable ; `email` change quand l'utilisateur le change
  groups_claim = "groups"     # ce qui alimente le groupe externe du §5.3
  oidc_scopes  = ["profile", "email", "groups"]

  allowed_redirect_uris = [
    "https://openbao.lan.wittner.tech/ui/vault/auth/oidc/oidc/callback",
    "http://localhost:8250/oidc/callback",
  ]

  # AUCUNE policy ici, et c'est délibéré : un utilisateur authentik quelconque obtient un token
  # qui ne sait rien lire. Les droits arrivent uniquement par appartenance au groupe (§5.3).
  token_policies = ["default"]
  token_ttl      = 3600
  token_max_ttl  = 28800
}
```

### 5.3 Du groupe authentik aux droits dans le coffre

OpenBao ne lit pas un claim pour en déduire une policy : il faut un **groupe externe** et un
**alias** portant le nom exact renvoyé dans le claim `groups`.

```hcl
resource "vault_policy" "openbao_admin" {
  name = "openbao-admin"

  # Plein pouvoir sur les DONNÉES, lecture seule sur la STRUCTURE. La structure (mounts, auth,
  # policies) est posée par ce Terraform : la modifier à la main dans l'UI créerait exactement
  # la dérive que le repo GitOps interdit à côté. Pour toucher à la structure → root token.
  policy = <<-EOT
    path "kv/data/*"     { capabilities = ["create", "read", "update", "patch", "delete", "list"] }
    path "kv/metadata/*" { capabilities = ["read", "list", "delete"] }
    path "kv/delete/*"   { capabilities = ["update"] }
    path "kv/undelete/*" { capabilities = ["update"] }

    path "sys/mounts"       { capabilities = ["read", "list"] }
    path "sys/auth"         { capabilities = ["read", "list"] }
    path "sys/policies/acl" { capabilities = ["read", "list"] }
    path "auth/*"           { capabilities = ["read", "list"] }

    # Ce dont l'UI a besoin pour ne pas afficher des pages vides.
    path "sys/health"           { capabilities = ["read", "sudo"] }
    path "sys/seal-status"      { capabilities = ["read"] }
    path "sys/capabilities-self" { capabilities = ["update"] }
  EOT
}

resource "vault_identity_group" "openbao_admin" {
  name     = "app-openbao-admin"
  type     = "external"          # « external » = peuplé par un claim, pas par une liste de membres
  policies = [vault_policy.openbao_admin.name]
}

resource "vault_identity_group_alias" "openbao_admin" {
  # ⚠️ DOIT être exactement la valeur présente dans le claim `groups` du token authentik,
  # c'est-à-dire le nom du groupe côté authentik. Une casse différente = aucun droit.
  name           = "app-openbao-admin"
  mount_accessor = vault_jwt_auth_backend.oidc.accessor
  canonical_id   = vault_identity_group.openbao_admin.id
}
```

### 5.4 Le `client_secret`, et pourquoi il ne va pas au KV

> [!WARNING]
> **Ce secret-ci passe forcément par Terraform** — c'est la seule exception à la règle de
> l'encadré en tête de document, et elle n'en est pas vraiment une : Terraform *crée* déjà le
> Provider authentik, donc le `client_secret` est dans son state depuis le premier `apply`,
> exactement comme ceux d'argocd et de grafana. Le traiter en conséquence : **state chiffré et
> hors Git**.
>
> Il **ne va pas** dans `kv/homelab/openbao/oidc`, contrairement à ses homologues. Les autres y
> sont parce qu'un consommateur *tiers* (ArgoCD, Grafana) doit les lire via un `ExternalSecret` ;
> ici le consommateur **est le coffre lui-même**, et la valeur vit déjà dans sa config d'auth.
> L'y recopier ajouterait une copie à faire tourner sans ajouter un seul lecteur — et un secret
> nécessaire au login, rangé derrière ce même login, est précisément la boucle que la règle
> anti-cycle de [regles-gitops.md](regles-gitops.md) interdit.

Passage de la valeur, sans jamais toucher un fichier :

```bash
export TF_VAR_openbao_oidc_client_secret="$(…)"   # ou lecture directe de la resource authentik
```

### 5.5 Se connecter

```bash
# UI : https://openbao.lan.wittner.tech → méthode « OIDC » → redirection authentik.
# CLI, depuis la racine du repo (le navigateur s'ouvre, le callback revient sur :8250) :
BAO_ADDR=https://openbao.lan.wittner.tech bao login -method=oidc
BAO_ADDR=https://openbao.lan.wittner.tech bao token capabilities kv/data/homelab/grafana/oidc
```

La seconde commande doit renvoyer les capacités de `openbao-admin`. `deny` seul = le token est
valide mais le groupe n'a pas été reconnu (§5.3).

⚠️ **Le coffre doit joindre `https://authentik.wittner.tech`** pour récupérer le document de
découverte et les JWKS : c'est le pod openbao qui sort, vers un nom **public**, depuis
l'intérieur du cluster. Le chemin est déjà éprouvé — ArgoCD fait exactement la même chose pour
son propre SSO — mais il suppose que le résolveur du réseau ne renvoie pas ce nom vers une IP
injoignable en hairpin depuis le cluster.

## Vérifier

```bash
kubectl -n openbao exec -ti openbao-0 -- bao secrets list          # kv/ présent
kubectl -n openbao exec -ti openbao-0 -- bao auth list             # kubernetes-<cluster>/ + oidc/
kubectl -n openbao exec -ti openbao-0 -- bao read auth/kubernetes-bleu-kalecgos/role/external-secrets
kubectl -n openbao exec -ti openbao-0 -- bao read auth/oidc/role/default
kubectl -n openbao exec -ti openbao-0 -- bao list identity/group/name    # app-openbao-admin
```

Test de bout en bout, en forgeant un token pour le ServiceAccount d'ESO — c'est le diagnostic le
plus direct, et son message d'erreur est bien plus précis que celui remonté par ESO :

```bash
TOKEN=$(kubectl -n external-secrets create token external-secrets)
kubectl -n openbao exec -i openbao-0 -- \
  bao write auth/kubernetes-bleu-kalecgos/login role=external-secrets jwt="$TOKEN"
```

Puis, côté cluster :

```bash
kubectl get clustersecretstore openbao -o yaml     # status.conditions → Ready=True
kubectl get externalsecrets -A                     # STATUS → SecretSynced
```

## Erreurs fréquentes

| Symptôme | Cause |
|---|---|
| `403 permission denied` au `/login`, y compris en manuel | **le mount n'existe pas** — OpenBao évalue l'ACL avant le routage, un chemin de login inconnu est refusé en 403, pas en 404. Vérifier `bao auth list` |
| `invalid role name` | le mount existe, le rôle non |
| `service account name not authorized` | `bound_service_account_names` ≠ `external-secrets` |
| `namespace not authorized` | `bound_service_account_namespaces` ≠ `external-secrets` |
| `lookup failed` / `service account unauthorized` | la TokenReview échoue : `audience` posée sur le rôle sans contrepartie côté store, ou (spoke) `kubernetes_host`/CA/`token_reviewer_jwt` faux |
| `permission denied` à la **lecture** d'un secret, login OK | la policy ne couvre pas le chemin — attention au `/data/` de KV v2 |
| `Vault is sealed` / `503` | le coffre est scellé, pas un problème de configuration |

Propres au login OIDC (§5) :

| Symptôme | Cause |
|---|---|
| authentik affiche `redirect_uri_error` | l'URI de callback réelle n'est pas dans le Provider — la lire dans **Events → Logs** d'authentik plutôt que la deviner |
| `invalid redirect_uri` renvoyé par **openbao** | l'URI est bonne côté authentik mais absente d'`allowed_redirect_uris` du rôle : les deux listes doivent coïncider |
| login OK mais tout est `denied` | l'alias de groupe ne correspond pas au claim — comparer au caractère près le nom du groupe authentik et `vault_identity_group_alias.name` |
| login OK, l'UI ne montre aucun secret engine | normal si la policy ne donne pas `list` sur `sys/mounts` |
| `error checking oidc discovery URL` | le pod openbao ne joint pas `authentik.wittner.tech` (DNS/hairpin), ou authentik est éteint |
| la méthode « OIDC » n'apparaît pas dans le menu de l'UI | `tune { listing_visibility = "unauth" }` manquant sur le mount |

## Ajouter un cluster

1. Créer `cluster/infra/external-secrets/<cluster>/manifests/` dans **ce** dépôt (kustomization +
   `ClusterSecretStore`), en partant d'un existant. L'`ApplicationSet` le découvre seul.
2. Si c'est un **spoke** : y ajouter aussi le `ServiceAccount` + `ClusterRoleBinding`
   `system:auth-delegator` + `Secret` de token, pour le `token_reviewer_jwt`.
3. Ajouter l'entrée dans `var.clusters` côté Terraform, et appliquer.
4. Vérifier avec le test de login ci-dessus.

Aucune valeur de secret n'est à recopier : le coffre est unique, les six secrets y sont déjà.

## Ce qui ne va PAS dans Terraform

- **Les valeurs des secrets** — elles finiraient dans le state. `bao kv put`, cf.
  [runbook-bootstrap.md](runbook-bootstrap.md) étape 8b. Seule exception, et par nécessité : le
  `client_secret` du Provider OIDC d'openbao (§5.4), que Terraform génère lui-même côté authentik.
- **Les comptes et les groupes** — `app-openbao-admin` est un groupe **authentik**, peuplé là-bas.
  Le coffre n'en connaît que le nom, via le claim `groups`.
- **Les clés de descellement et le token root** — coffre hors ligne, ils protègent tout le reste.
- **Le RBAC Kubernetes** (le `ServiceAccount` reviewer d'un spoke) — c'est une ressource
  Kubernetes, donc du GitOps, donc ce dépôt-ci.
- **Les credentials d'un futur snapshot vers S3/MinIO** — règle anti-cycle : un secret dont
  openbao a besoin ne peut pas venir d'openbao, il doit être un `SealedSecret`
  ([regles-gitops.md](regles-gitops.md)).
