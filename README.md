# homelab-gitops

```
homelab-gitops/
├── bootstrap/
│   └── root.yaml                         # app-of-apps — appliqué à la main UNE fois
│
├── infra/
│   └── argocd/                           # CE dossier sert aux DEUX usages
│       ├── kustomization.yaml            # ton kustomize (bumpé, nettoyé)
│       ├── namespace.yaml
│       ├── argocd-cmd-params-cm.patch.yaml
│       ├── argocd-cm.patch.yaml
│       ├── argocd-rbac-cm.patch.yaml
│       ├── argocd-secret-patch.yaml
│       ├── ingress.yaml                  # présent mais PAS encore dans kustomization.yaml
│       └── argocd.sealed-secret.yaml     # présent mais PAS encore dans kustomization.yaml
│
└── apps-definitions/
    └── neltharion/
        └── argocd.app.yaml               # l'Application qui pointe sur infra/argocd
```