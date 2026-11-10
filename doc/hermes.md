# Hermes

[Hermes Agent](https://hermes-agent.nousresearch.com/) (Nous Research) en mode **gateway** : un pod, trois services supervisés par s6 (passerelle messagerie, API OpenAI-compatible `8642`, dashboard `9119`). Sur kalecgos, namespace `hermes`. Référence amont : [user-guide/docker.md](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/docker.md) (pas le Quickstart, installation locale).

| Fichier | Rôle |
|---|---|
| `clusters/bleu-kalecgos/hermes/hermes.app.yaml` | `hermes-kalecgos` : manifestes simples |
| `clusters/bleu-kalecgos/hermes/manifests/statefulset.yaml` | 1 réplica, PVC 15 Gi `openebs-lvm` sur `/opt/data`, aucun initContainer |
| `clusters/bleu-kalecgos/hermes/manifests/config/hermes.env` | variables non secrètes (API, dashboard, OIDC) → ConfigMap `hermes-vars` |
| `clusters/bleu-kalecgos/hermes/manifests/externalsecret.yaml` | `secret/hermes` → Secret `hermes-env` (`API_SERVER_KEY`) |
| `clusters/bleu-kalecgos/hermes/manifests/httproute.yaml` | `hermes.lan.wittner.tech` → dashboard, `hermes-api.lan.wittner.tech` → API |
| `clusters/bleu-malygos/external-services/manifests/hermes.yaml` | relais des deux hostnames vers kalecgos |
| `clusters/bleu-malygos/authelia/manifests/config/clients.yml` | client OIDC `hermes` (public, PKCE) |
| `clusters/bleu-kalecgos/velero/manifests/schedule-hermes.yaml` | Velero chaque nuit (03:00 UTC), 30 jours |

## Contraintes

| Point | |
|---|---|
| Code arbitraire | l'agent exécute dans le pod du code décidé par un LLM (`terminal.backend: local`). Garde-fous : `automountServiceAccountToken: false`, aucun RBAC. Sortie réseau **libre** ([décisions](decisions.md)) |
| Exposition | LAN seulement ; jamais de route publique (dashboards et API exposés compromis en juin 2026, doc amont) |
| Root au démarrage | voulu : s6 chown `/opt/data` puis passe en uid 10000. Pas de `runAsNonRoot`, pas de `command:` (l'ENTRYPOINT lance s6) |
| Dashboard | refuse de démarrer sans fournisseur d'auth sur un bind non-loopback ; ici OIDC Authelia |
| Messagerie | un token invalide fait sortir toute la gateway (et l'API avec). Pas de messagerie voulue = variable absente, jamais de placeholder |
| État | tout dans `/opt/data` (`config.yaml`, skills, mémoire, `auth.json`, sessions) ; seul filet : Velero. PVC neuf = vide |
| Secrets | tout `hermes-env` est lisible par l'agent : jetons aux droits restreints seulement |
| PVC RWO | rollout avec coupure |

## Avant le premier sync (une fois)

```sh
export BAO_ADDR=https://openbao.lan.wittner.tech
bao login -method=oidc
bao kv put secret/hermes api_server_key="$(openssl rand -hex 32)"
```

Sans `secret/hermes`, le pod reste en `CreateContainerConfigError`. Client Authelia : public, aucun secret.

## Premier boot sur PVC neuf

Les sondes sont **commentées** dans `statefulset.yaml` le temps de l'init (sinon kubelet tue le conteneur au bout de 11 min). Pendant ce temps, `1/1 Running` ne prouve rien : se fier aux logs.

1. Profil shell (sans lui, l'outil terminal de l'agent perd `/opt/hermes/bin` du `PATH` : `/etc/profile` l'écrase). Jamais de `~/.bash_profile` ni `~/.bash_login` (bash ignorerait `.profile`).

   ```sh
   kubectl --context admin@bleu-kalecgos -n hermes exec -i hermes-0 -c hermes -- sh -s <<'EOF'
   install -d -o 10000 -g 10000 -m 0755 /opt/data/home
   printf 'export PATH="/opt/hermes/bin:/opt/hermes/.venv/bin:$PATH"\n' > /opt/data/home/.profile
   chown 10000:10000 /opt/data/home/.profile
   EOF
   ```

2. Modèle et fournisseur dans `/opt/data/config.yaml`. Vu en v2026.9.24 : le défaut `provider: "auto"` + `base_url` fige la gateway au démarrage, sans aucun log (`openrouter` aussi). Valeur sûre : `custom` ou une vraie clé (`openai-codex`, `anthropic`, `nous`…). Avant :

   ```yaml
   model:
     default: gpt-5.6-terra
     provider: openai-codex
     base_url: https://chatgpt.com/backend-api/codex
     api_mode: codex_responses
   ```

3. Connexion au fournisseur LLM : flux device code à la main (écrit `/opt/data/auth.json`, hors Git).
4. Relancer la gateway sans redémarrer le pod, puis vérifier les deux ports :

   ```sh
   kubectl --context admin@bleu-kalecgos -n hermes exec hermes-0 -c hermes -- /package/admin/s6/command/s6-svc -r /run/service/gateway-default
   kubectl --context admin@bleu-kalecgos -n hermes exec hermes-0 -c hermes -- sh -c \
     'for p in 8642 9119; do printf "%s -> " $p; curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:$p/; done'
   # attendu : 8642 -> 404, 9119 -> 302
   ```

5. Décommenter les sondes, commit, push.

`kubectl exec` entre en **root** : tout fichier créé à la main → `chown 10000:10000`, sinon `Permission denied` côté Hermes.

Reprendre l'ancien état : dépôt `jbwittner/homelab_hermes` (figé au 2026-10-22), copie manuelle de ce qu'on veut garder (`config.yaml`, `SOUL.md`, `skills/`), puis `chown`.

## Accès

| | |
|---|---|
| Dashboard | <https://hermes.lan.wittner.tech>, connexion Authelia |
| API | `https://hermes-api.lan.wittner.tech/v1/…`, en-tête `Authorization: Bearer <API_SERVER_KEY>` |

Connexion qui boucle sur la page de login (cookie `Secure` non posé derrière le Gateway) : dans `/opt/data/config.yaml`, `dashboard.trusted_proxies: ["10.244.0.0/16"]` (CIDR pods de kalecgos ; Hermes refuse `0.0.0.0/0`), puis supprimer le pod.

## Changer un secret

Un `envFrom` ne suit pas le Secret : redémarrer le pod.

```sh
bao kv patch secret/hermes <champ>="<valeur>"
kubectl --context admin@bleu-kalecgos -n hermes annotate externalsecret hermes-env force-sync=$(date +%s) --overwrite
kubectl --context admin@bleu-kalecgos -n hermes delete pod hermes-0
```

Discord : `DISCORD_BOT_TOKEN`, `DISCORD_HOME_CHANNEL`, `DISCORD_ALLOWED_USERS` (dans le secret : elle décide qui pilote l'agent ; jamais `DISCORD_ALLOW_ALL_USERS`). Champs dans `secret/hermes` **et** lignes dans `externalsecret.yaml`, dans cet ordre.

## Mémoire (holographic)

SQLite local, aucune clé ni service externe. Une fois par PVC :

```sh
kubectl --context admin@bleu-kalecgos -n hermes exec -i hermes-0 -c hermes -- sh -s <<'EOF'
export PATH="/opt/hermes/bin:/opt/hermes/.venv/bin:$PATH"
hermes config set memory.provider holographic
chown 10000:10000 /opt/data/config.yaml
EOF
kubectl --context admin@bleu-kalecgos -n hermes delete pod hermes-0
```

| Point | |
|---|---|
| Base | `/opt/data/memory_store.db` ; un `db_path` en `~` dans le `config.yaml` racine est hérité par tous les profils (une base partagée) |
| NumPy | absent de l'image en v2026.9.24 : `probe`, `reason`, `contradict` inertes (repli sur la recherche FTS) |
| Inspection | jamais ouvrir la base en root (un `-wal`/`-shm` root bloque la gateway) ; pas de `sqlite3` dans l'image |

## Agrandir le PVC

`volumeClaimTemplates` immuable et sans effet sur le PVC existant : deux opérations.

```sh
kubectl --context admin@bleu-kalecgos -n hermes delete statefulset hermes --cascade=orphan   # après le commit ; ArgoCD le recrée
kubectl --context admin@bleu-kalecgos -n hermes patch pvc data-hermes-0 -p '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}'
kubectl --context admin@bleu-kalecgos -n hermes get pvc data-hermes-0 -w                      # FileSystemResizePending se résout seul
```

## Repartir de zéro

Tout est perdu (pour récupérer : restauration Velero, [sauvegardes](sauvegardes.md)). `kubectl scale` est annulé par ArgoCD : `replicas: 0` par commit, puis :

```sh
kubectl --context admin@bleu-kalecgos -n hermes delete pvc data-hermes-0   # irréversible
```

`replicas: 1` par commit, puis « Premier boot sur PVC neuf ».

## Vérifier

```sh
kubectl --context admin@bleu-kalecgos -n hermes get sts,pod,pvc,externalsecret,httproute
kubectl --context admin@bleu-kalecgos -n hermes logs hermes-0 -f
kubectl --context admin@bleu-kalecgos -n velero get schedule hermes
```
