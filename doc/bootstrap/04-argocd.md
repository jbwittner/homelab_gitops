# 4. ArgoCD (malygos)

Kustomize sur `install.yaml` taguée. Ensuite ArgoCD se gère lui-même (`malygos-argocd`) et une app-of-apps par cluster (`malygos-apps`, `kalecgos-apps`) charge les `*.app.yaml` de son dossier.

| Fichier (`clusters/bleu-malygos/` sauf mention) | Rôle |
|---|---|
| `argocd/manifests/kustomization.yaml` | namespace + `install.yaml` + secrets |
| `argocd/manifests/cluster-bleu-malygos.yaml` | cluster local nommé `bleu-malygos`, label `role=infra` |
| `argocd/manifests/github-app.sealed.yaml` | accès Git (`repo-creds` sur `https://github.com/jbwittner`) ; modèle : `github-app.secret.example.yaml` |
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

```sh
cp clusters/bleu-malygos/argocd/manifests/github-app.secret.example.yaml \
   clusters/bleu-malygos/argocd/manifests/github-app.secret.yaml
```

Remplir `github-app.secret.yaml` (`stringData`) : App ID, Installation ID, contenu du `.pem`. Puis :

```sh
kubeseal --context admin@bleu-malygos -o yaml \
  < clusters/bleu-malygos/argocd/manifests/github-app.secret.yaml \
  > clusters/bleu-malygos/argocd/manifests/github-app.sealed.yaml
command rm clusters/bleu-malygos/argocd/manifests/github-app.secret.yaml
```

Supprimer aussi le `.pem` téléchargé. Clé perdue : en générer une nouvelle sur la GitHub App et resceller ; rien à sauvegarder.

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

Les Applications `kalecgos-*` restent en erreur (`cluster bleu-kalecgos not found`) jusqu'à l'étape 5.

## Vérifier

```sh
kubectl --context admin@bleu-malygos -n argocd get applications    # malygos-* Synced / Healthy
```

Interface (en attendant la Gateway) :

```sh
kubectl --context admin@bleu-malygos -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
kubectl --context admin@bleu-malygos -n argocd port-forward svc/argocd-server 8080:443
```

`https://localhost:8080`, utilisateur `admin`. Changer le mot de passe, puis supprimer `argocd-initial-admin-secret`.
