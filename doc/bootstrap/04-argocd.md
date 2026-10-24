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

Rotation (clé perdue ou exposée) : nouvelle clé sur la GitHub App, supprimer l'ancienne, refaire cette section. Rien à sauvegarder.

Commit + push du `.sealed.yaml`.

## 3. Installer

```sh
kubectl --context admin@bleu-malygos apply --server-side --force-conflicts \
  -k clusters/bleu-malygos/argocd/manifests

kubectl --context admin@bleu-malygos -n argocd rollout status deploy/argocd-repo-server
kubectl --context admin@bleu-malygos -n argocd rollout status statefulset/argocd-application-controller

kubectl --context admin@bleu-malygos apply \
  -f clusters/bleu-malygos/apps.app.yaml -f clusters/bleu-kalecgos/apps.app.yaml
```

Les Applications `*-kalecgos` restent en erreur (`there are no clusters with this name: bleu-kalecgos`) jusqu'à l'[étape 5](05-kalecgos.md).

## Vérifier

```sh
kubectl --context admin@bleu-malygos -n argocd get applications    # *-malygos Synced / Healthy
```

Interface (en attendant la Gateway) :

```sh
kubectl --context admin@bleu-malygos -n argocd port-forward svc/argocd-server 8080:443
```

`https://localhost:8080`, utilisateur `admin`.

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
