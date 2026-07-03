# Authentik

Fournisseur **SSO / OIDC** (stack Dokploy / Docker Compose). Sert d'IdP pour les autres
services (ex. Grafana via OAuth2 generic). Exposé sur `authentik.wittnerlab.com`.

## Services

| Conteneur | Image | Rôle |
|---|---|---|
| `authentication_authentik_server` | `ghcr.io/goauthentik/server` (`server`) | UI + API + endpoint OIDC |
| `authentication_authentik_worker` | `ghcr.io/goauthentik/server` (`worker`) | tâches de fond (a accès à `docker.sock`) |
| `authentication_authentik_postgresql` | `postgres` | base de données |
| `authentication_authentik_redis` | `redis` | cache / file de tâches |

## Réseaux

| Réseau | Type | Rôle |
|---|---|---|
| `authentik_net` | bridge interne | `server`/`worker` ↔ `postgresql`/`redis` |
| `messaging_net` | **externe** | joindre le relais SMTP Postfix (`messaging/postfix`) |

`messaging_net` est partagé ; le créer une fois sur l'hôte avant de lancer la stack :

```bash
docker network create messaging_net
```

## Envoi de mails (SMTP via Postfix)

Authentik relaie ses mails (invitations, reset password…) via le relais Postfix de
[`messaging/postfix`](../../messaging/postfix/README.md). authentik **vérifie le certificat
TLS** : on vise donc le relais par l'alias réseau `postfix.wittnerlab.com` (= CN du cert
Let's Encrypt), pas par le nom de conteneur, sinon le handshake STARTTLS échoue
(`SSL alert 42 bad_certificate`). Le user SASL dédié `authentik-noreply@wittnerlab.com` doit
exister dans `SMTP_USER` côté Postfix.

## Variables d'environnement

Copier `example.env` en `.env` (gitignored) et compléter :

| Variable | Rôle |
|---|---|
| `PG_USER` / `PG_DB` / `PG_PASS` | credentials PostgreSQL |
| `AUTHENTIK_SECRET_KEY` | clé secrète (`openssl rand -base64 60`) |
| `MAILER_SMTP_ADDR` / `MAILER_SMTP_PORT` | relais SMTP (`postfix.wittnerlab.com:587`) |
| `MAILER_USER` / `MAILER_PASSWD` | SASL (doit matcher `SMTP_USER` Postfix) |
| `MAILER_FROM` | adresse d'expédition |

> Variante Kubernetes archivée sous [`archive/neltharion/authentik/`](../../../archive/neltharion/authentik/README.md).
