# 4. ArgoCD (malygos)

Kustomize sur `install.yaml` taguée. Ensuite ArgoCD se gère lui-même (`argocd-malygos`) et une app-of-apps par cluster (`apps-malygos`, `apps-kalecgos`) charge les `*.app.yaml` de son dossier.

| Fichier (`clusters/bleu-malygos/` sauf mention) | Rôle |
|---|---|
| `argocd/manifests/kustomization.yaml` | namespace + `install.yaml` + secrets |
| `argocd/manifests/cluster-bleu-malygos.yaml` | cluster local nommé `bleu-malygos`, label `role=infra` |
| `argocd/manifests/github-app.sealed.yaml` | accès Git (`repo-creds` sur `https://github.com/jbwittner`) ; modèle : `github-app.secret.example.yaml` |
| `argocd/manifests/admin-password.sealed.yaml` | mot de passe `admin` (patch de `argocd-secret`) ; modèle : `admin-password.secret.example.yaml` |
| `argocd/argocd.app.yaml` | ArgoCD géré par ArgoCD |
| `clusters/<nom>/apps.app.yaml` | app-of-apps du cluster : `clusters/<nom>/**/*.app.yaml` |

## 1. GitHub App (une fois)

GitHub → Settings → Developer settings → GitHub Apps → New GitHub App :

| Champ | Valeur |
|---|---|
| Homepage URL | `https://github.com/jbwittner/homelab_gitops` |
| Webhook | décoché |
| Repository permissions | Contents : Read-only (Metadata : Read-only, imposé) |
| Installable | Only on this account |

Puis :
- noter l'**App ID** ;
- Generate a private key (fichier `.pem` téléchargé) ;
- Install App → Only select repositories → `homelab_gitops` ; l'**Installation ID** est la fin de l'URL `github.com/settings/installations/<ID>`.

## 2. Sceller l'accès Git

App ID et Installation ID sont déjà dans le modèle (non sensibles). Remplir la clé depuis le `.pem` téléchargé, sceller, nettoyer :

```sh
KEY=$(cat ~/Downloads/<app>.<date>.private-key.pem) \
yq '.stringData.githubAppPrivateKey = strenv(KEY)' \
  clusters/bleu-malygos/argocd/manifests/github-app.secret.example.yaml \
  > clusters/bleu-malygos/argocd/manifests/github-app.secret.yaml

kubeseal --context admin@bleu-malygos -o yaml \
  < clusters/bleu-malygos/argocd/manifests/github-app.secret.yaml \
  > clusters/bleu-malygos/argocd/manifests/github-app.sealed.yaml

command rm clusters/bleu-malygos/argocd/manifests/github-app.secret.yaml ~/Downloads/<app>.<date>.private-key.pem
```

Commit + push du `.sealed.yaml`. Changer de clé : [rotation](#rotation-de-la-clé).

## 3. Installer

```sh
kubectl --context admin@bleu-malygos apply --server-side --force-conflicts \
  -k clusters/bleu-malygos/argocd/manifests

kubectl --context admin@bleu-malygos -n argocd rollout status deploy/argocd-repo-server
kubectl --context admin@bleu-malygos -n argocd rollout status statefulset/argocd-application-controller

kubectl --context admin@bleu-malygos apply \
  -f clusters/bleu-malygos/apps.app.yaml -f clusters/bleu-kalecgos/apps.app.yaml
```

Erreurs attendues au premier boot :

| Erreur | Cause | Levée par |
|---|---|---|
| `no matches for kind "ExternalSecret"` (au `apply -k`, le reste est appliqué) | `oidc.externalsecret.yaml` : CRD posée par `external-secrets-malygos` | `argocd-malygos` la pose ensuite (retry sans fin) |
| `there are no clusters with this name: bleu-kalecgos` | Applications `*-kalecgos` | [étape 5](05-kalecgos.md) |

## Vérifier

```sh
kubectl --context admin@bleu-malygos -n argocd get applications    # *-malygos Synced / Healthy
```

Interface : `https://argocd.lan.wittner.tech` ([exposition](../exposition.md)), connexion Authelia (après l'[étape 6](06-openbao.md)), `admin` en secours. CLI : `argocd login argocd.lan.wittner.tech --grpc-web`.

Avant la Gateway (premier boot) :

```sh
kubectl --context admin@bleu-malygos -n argocd port-forward svc/argocd-server 8080:80
```

`http://localhost:8080` (`server.insecure` : TLS terminé au Gateway).

## Mot de passe admin

Générer le mot de passe, son hash et la date, et remplir `admin-password.secret.yaml` depuis le modèle :

```sh
PASS=$(openssl rand -base64 24); echo "$PASS"   # à ranger dans le gestionnaire de mots de passe

HASH=$(argocd account bcrypt --password "$PASS") MTIME=$(date -u +%Y-%m-%dT%H:%M:%SZ) \
yq '.stringData."admin.password" = strenv(HASH) | .stringData."admin.passwordMtime" = strenv(MTIME)' \
  clusters/bleu-malygos/argocd/manifests/admin-password.secret.example.yaml \
  > clusters/bleu-malygos/argocd/manifests/admin-password.secret.yaml
unset PASS
```

Sceller :

```sh
kubeseal --context admin@bleu-malygos -o yaml \
  < clusters/bleu-malygos/argocd/manifests/admin-password.secret.yaml \
  > clusters/bleu-malygos/argocd/manifests/admin-password.sealed.yaml
command rm clusters/bleu-malygos/argocd/manifests/admin-password.secret.yaml
```

Commit + push. Une fois le nouveau mot de passe accepté :

```sh
kubectl --context admin@bleu-malygos -n argocd delete secret argocd-initial-admin-secret
```

Changer de mot de passe : refaire la section (nouveau hash, nouvelle date).

## Rotation de la clé

Clé perdue, exposée ou supprimée côté GitHub. Symptôme : `401 Unauthorized` sur `…/app/installations/<id>/access_tokens` (logs d'`argocd-repo-server`), toutes les Applications en `Unknown`.

1. GitHub App → Private keys → Generate a private key ; noter l'empreinte `SHA256:…` affichée.
2. Vérifier le `.pem` téléchargé (même empreinte que GitHub) :
   ```sh
   PEM=$(command ls -t ~/Downloads/*.pem | head -1); echo $PEM
   openssl rsa -in $PEM -pubout -outform DER 2>/dev/null | openssl sha256 -binary | openssl base64
   ```
3. Section 2 avec `KEY=$(cat $PEM)`. Avant `kubeseal`, revérifier le fichier en clair (une clé vide se scelle sans erreur) :
   ```sh
   yq '.stringData.githubAppPrivateKey' clusters/bleu-malygos/argocd/manifests/github-app.secret.yaml \
     | openssl rsa -pubout -outform DER 2>/dev/null | openssl sha256 -binary | openssl base64
   ```
4. Commit + push **avant** d'appliquer : dès l'accès retrouvé, `argocd-malygos` (selfHeal) réapplique ce qui est dans Git.
5. Attendre 1 min (cache de résolution de `main` du repo-server = `timeout.reconciliation`, sinon il ressert l'ancien commit), puis :
   ```sh
   kubectl --context admin@bleu-malygos apply -f clusters/bleu-malygos/argocd/manifests/github-app.sealed.yaml
   ```
6. Supprimer l'ancienne clé sur GitHub si elle y est encore.

Vérifier :

```sh
kubectl --context admin@bleu-malygos -n argocd logs deploy/argocd-repo-server --since=2m | grep -c 401   # 0
kubectl --context admin@bleu-malygos -n argocd get application argocd-malygos -o jsonpath='{.status.sync.revision}'; echo
git rev-parse origin/main                                                                                 # même commit
```
