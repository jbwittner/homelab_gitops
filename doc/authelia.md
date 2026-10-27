# Authelia (malygos)

Fournisseur OIDC : `https://auth.lan.wittner.tech`. Un utilisateur (`jbwittner`, groupe `admins`), mot de passe + second facteur (passkey ou TOTP).

| Fichier (`clusters/bleu-malygos/authelia/`) | Rôle |
|---|---|
| `authelia.app.yaml` | `authelia-malygos` : manifestes simples, image officielle `ghcr.io/authelia/authelia` |
| `manifests/statefulset.yaml` | 1 réplica, PVC 100 Mi `openebs-lvm` (`/config` : SQLite, notifications) |
| `manifests/config/configuration.yml` | config Authelia ([doc](https://www.authelia.com/configuration/)) ; filtre `template` : pas d'accolades, même en commentaire |
| `manifests/config/clients.yml` | clients OIDC, **tous ici** |
| `manifests/externalsecret.yaml` | `secret/authelia` → Secret `authelia` (clés, fichier des utilisateurs) |

Pas de forward-auth : le Gateway Cilium ne le fait pas. Seules les applis OIDC sont protégées ([décisions](decisions.md)).

| Client | Côté appli | Secret en clair |
|---|---|---|
| `argocd`, `argocd-cli` | `argocd/manifests/kustomization.yaml` (`argocd-cm`, `argocd-rbac-cm`) | `secret/argocd` → `oidc_client_secret` |
| `grafana` | `kube-prometheus-stack/values.yaml` (`auth.generic_oauth`) | `secret/grafana` → `oidc_client_secret` |
| `openbao` | `homelab_terraform`, `openbao/bleu-malygos/auth_oidc.tf` (secret lu en éphémère, hors state) | `secret/openbao` → `oidc_client_secret` |

Secours : `admin` ArgoCD, `admin` Grafana et `userpass` OpenBao restent actifs.

## Secrets (une fois)

CLI locale connectée à OpenBao ([openbao](openbao.md)), Docker pour les hash. Rien n'est affiché.

```sh
export BAO_ADDR=https://openbao.lan.wittner.tech
bao login -method=oidc
```

Authelia : clés, mot de passe, e-mail.

```sh
read -rs "PASS?Mot de passe Authelia : "; echo
HASH=$(docker run --rm ghcr.io/authelia/authelia authelia crypto hash generate argon2 --password "$PASS" | sed -n 's/^Digest: \(\$.*\)/\1/p'); unset PASS
read "EMAIL?E-mail : "
bao kv put secret/authelia \
  session_secret="$(openssl rand -hex 32)" \
  storage_encryption_key="$(openssl rand -hex 32)" \
  oidc_hmac_secret="$(openssl rand -hex 32)" \
  oidc_jwks_key="$(openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 2>/dev/null)" \
  user_password_hash="$HASH" user_email="$EMAIL"
unset HASH EMAIL
```

`storage_encryption_key` chiffre la base : ne plus jamais le changer (sinon passkeys et TOTP à réenregistrer).

## Ajouter un client

Secret en clair dans OpenBao côté appli, hash affiché (non sensible) pour `clients.yml` :

```sh
S=$(openssl rand -hex 32)
bao kv patch secret/<comp> oidc_client_secret="$S"     # put si secret/<comp> n'existe pas
docker run --rm ghcr.io/authelia/authelia authelia crypto hash generate pbkdf2 --variant sha512 --password "$S" | sed -n 's/^Digest: //p'
unset S
```

Puis, dans le même commit : entrée dans `clients.yml` (`client_secret` = hash ; modèles : [intégrations](https://www.authelia.com/integration/openid-connect/clients/)), config OIDC de l'appli, ExternalSecret côté appli.

## Second facteur (une fois)

Se connecter sur `https://auth.lan.wittner.tech`, enregistrer une passkey (ou un TOTP). Pas de SMTP : le code de vérification, à usage unique, est écrit sur le PVC :

```sh
kubectl --context admin@bleu-malygos -n authelia exec authelia-0 -- cat /config/notification.txt
```

## Changer le mot de passe

Le fichier des utilisateurs est lu au démarrage :

```sh
read -rs "PASS?Nouveau mot de passe : "; echo
bao kv patch secret/authelia user_password_hash="$(docker run --rm ghcr.io/authelia/authelia authelia crypto hash generate argon2 --password "$PASS" | sed -n 's/^Digest: \(\$.*\)/\1/p')"; unset PASS
kubectl --context admin@bleu-malygos -n authelia annotate externalsecret authelia force-sync=$(date +%s) --overwrite
kubectl --context admin@bleu-malygos -n authelia delete pod authelia-0
```

## Vérifier

```sh
kubectl --context admin@bleu-malygos -n authelia get pods,externalsecret,httproute
curl -s https://auth.lan.wittner.tech/api/health                                   # {"status":"OK"}
curl -s https://auth.lan.wittner.tech/.well-known/openid-configuration | jq .issuer
```

Sauvegarde : aucune. Config dans Git, utilisateurs et clés dans OpenBao ; PVC perdu = passkey et TOTP à réenregistrer.
