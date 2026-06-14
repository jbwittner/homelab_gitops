---
title: Postfix SMTP relay sur Dokploy — du minimum au TLS
tags:
  - dokploy
  - postfix
  - smtp
  - letsencrypt
  - cloudflare
  - homelab
created: 2026-05-08
---

# Postfix SMTP relay — Dokploy

Note pédagogique en deux temps :

1. **Étape 1 — minimum viable** : envoyer des mails sans TLS (juste Postfix + SASL + DKIM).
2. **Étape 2 — durcissement TLS** : ajouter un certificat Let's Encrypt obtenu via DNS-01 Cloudflare.

> [!info] Cas d'usage
> Relais SMTP authentifié pour envoyer des mails transactionnels depuis des apps internes (notifications, alertes, formulaires) en utilisant un domaine maison.

---

# Étape 1 — Le strict minimum (sans TLS)

L'objectif ici est juste de **faire sortir un mail** depuis le serveur, sans se soucier du chiffrement de la connexion entre le client SMTP et Postfix.

> [!warning] Pas pour la prod
> Sans TLS, les credentials SASL transitent **en clair** sur le réseau. Cette étape est uniquement pédagogique ou pour un test sur un réseau de confiance (Docker bridge local). En vrai déploiement, passer directement à l'étape 2.

## Ce qu'il faut

| Élément | Pour quoi faire |
|---|---|
| Un FQDN (ex. `postfix.wittnerlab.com`) | Identité du serveur SMTP, utilisé dans le `EHLO` et la signature DKIM |
| Un enregistrement DNS **A** vers l'IP du host | Pour que les serveurs distants puissent retrouver l'origine |
| Un domaine émetteur (`wittnerlab.com`) | Le `From:` des mails sortants |
| Un PTR (reverse DNS) `<IP> → postfix.wittnerlab.com` | **Critique** pour la délivrabilité (Gmail/Outlook rejettent sans) |
| Une image Postfix préconfigurée | Ici [`boky/postfix`](https://github.com/bokysan/docker-postfix) — expose tout via env `POSTFIX_<param>` |

## Compose minimal

```yaml
services:
  postfix_sender:
    image: boky/postfix:5.1.0
    container_name: mail_sender
    restart: unless-stopped
    ports:
      - "587:587"
    environment:
      - HOSTNAME=${HOSTNAME}
      - ALLOWED_SENDER_DOMAINS=${ALLOWED_SENDER_DOMAINS}
      - ENABLE_OPENDKIM=true
      - DKIM_AUTOGENERATE=true
      - SMTPD_SASL_USERS=${SMTP_USER}
      - POSTFIX_smtpd_sender_restrictions=permit_sasl_authenticated, permit_mynetworks, reject_non_fqdn_sender, reject_unknown_sender_domain
      - POSTFIX_smtpd_relay_restrictions=permit_sasl_authenticated, permit_mynetworks, reject_unauth_destination
    volumes:
      - dkim_data:/etc/opendkim/keys

volumes:
  dkim_data:
    driver: local
```

## Détail des variables

| Variable | Rôle |
|---|---|
| `HOSTNAME` | FQDN du serveur. Utilisé dans `EHLO` et comme identité DKIM. Doit matcher le DNS A et le PTR. |
| `ALLOWED_SENDER_DOMAINS` | Liste de domaines pour lesquels Postfix accepte d'émettre. Sans ça, l'image rejette tout. |
| `SMTP_USER` | Identifiants SASL `user:password`. Plusieurs users séparés par espaces. |
| `ENABLE_OPENDKIM` + `DKIM_AUTOGENERATE` | Active OpenDKIM et génère une paire de clés au premier démarrage. |

## Restrictions Postfix expliquées

```
smtpd_sender_restrictions = permit_sasl_authenticated, permit_mynetworks, reject_non_fqdn_sender, reject_unknown_sender_domain
smtpd_relay_restrictions  = permit_sasl_authenticated, permit_mynetworks, reject_unauth_destination
```

Postfix évalue les règles dans l'ordre, première qui matche gagne :

- `permit_sasl_authenticated` → user authentifié OK
- `permit_mynetworks` → conteneurs du réseau Docker interne OK
- `reject_*` → tout le reste est rejeté

Ces restrictions empêchent le serveur de devenir un **open relay** (ce qui le mettrait sur des blacklists en quelques heures).

## DKIM

OpenDKIM signe chaque mail sortant avec une clé privée. Les serveurs destinataires vérifient la signature en récupérant la **clé publique** publiée en DNS.

Au 1er démarrage, la clé est générée dans `/etc/opendkim/keys/<domain>/<selector>.txt`. Il faut la publier :

```sh
docker exec mail_sender cat /etc/opendkim/keys/wittnerlab.com/mail.txt
```

Puis créer un TXT en DNS :

```
<selector>._domainkey.wittnerlab.com  TXT  "v=DKIM1; k=rsa; p=MIGf..."
```

## DNS minimum à configurer

| Type | Nom | Valeur |
|---|---|---|
| A | `postfix.wittnerlab.com` | `<IP du host>` |
| TXT | `wittnerlab.com` | `v=spf1 mx ip4:<IP> -all` (SPF) |
| TXT | `<selector>._domainkey.wittnerlab.com` | clé DKIM publique |
| TXT | `_dmarc.wittnerlab.com` | `v=DMARC1; p=none; rua=mailto:...` |
| PTR | reverse de `<IP>` | `postfix.wittnerlab.com` (à demander à l'hébergeur) |

## Tester l'envoi (sans TLS)

```sh
curl --url 'smtp://postfix.wittnerlab.com:587' \
  --mail-from 'noreply@wittnerlab.com' \
  --mail-rcpt 'jeanbaptiste.wittner@outlook.com' \
  --upload-file test_mail.txt \
  --user 'noreply@wittnerlab.com:<password>'
```

À ce stade le serveur **fonctionne** mais la connexion client → Postfix est en clair.

---

# Étape 2 — Ajout de TLS (Let's Encrypt + DNS-01 Cloudflare)

## Pourquoi TLS

- Les credentials SASL ne doivent **jamais** transiter en clair.
- Beaucoup de serveurs destinataires (Gmail, Outlook) **dégradent le score** des mails reçus sans STARTTLS sur la connexion d'envoi.
- C'est gratuit avec Let's Encrypt — aucune raison de s'en passer.

## Pourquoi DNS-01 Cloudflare plutôt que HTTP-01

- HTTP-01 nécessite que le port **80 soit ouvert et accessible** depuis l'internet pour répondre au challenge ACME.
- DNS-01 prouve la propriété du domaine en créant un enregistrement TXT temporaire via l'API du registrar/DNS (Cloudflare ici). **Aucun port à ouvrir**.
- DNS-01 permet aussi d'émettre des **wildcards** (`*.wittnerlab.com`) si besoin plus tard.

## Architecture finale

```
                       ┌──────────────────────────────────┐
                       │  Dokploy host                    │
                       │                                  │
  client SMTP ────────►│  postfix_sender (boky/postfix)   │
   (port 587 + TLS)    │   - SASL auth                    │
                       │   - STARTTLS                     │
                       │   - OpenDKIM                     │
                       │           ▲                      │
                       │           │ lit certs (ro)       │
                       │           │                      │
                       │  postfix_certs_data (volume)     │
                       │           ▲                      │
                       │           │ écrit certs          │
                       │           │                      │
                       │  certbot (one-shot)              │
                       │   - DNS-01 via Cloudflare API    │
                       │   - cloudflare.ini (bind-mount)  │
                       └──────────────────────────────────┘
```

Deux services :

1. **`certbot`** — démarre, demande/renouvelle le cert via DNS-01, copie les fichiers dans un volume partagé, puis quitte (`service_completed_successfully`).
2. **`postfix_sender`** — démarre **après** certbot (`depends_on`), monte le volume des certs en lecture seule.

## Le service `certbot`

```yaml
certbot:
  image: certbot/dns-cloudflare
  entrypoint: ["/bin/sh", "-c"]
  command:
    - |
      set -e
      certbot certonly \
        --dns-cloudflare \
        --dns-cloudflare-credentials /cloudflare-secret/cloudflare.ini \
        --dns-cloudflare-propagation-seconds 20 \
        --email "${LETSENCRYPT_EMAIL}" \
        --agree-tos --no-eff-email \
        -d "${HOSTNAME}" \
        --non-interactive \
        --keep-until-expiring \
        --server "${LETSENCRYPT_SERVER}"
      mkdir -p /opt/postfix-certs
      cp -L /etc/letsencrypt/live/${HOSTNAME}/fullchain.pem /opt/postfix-certs/fullchain.pem
      cp -L /etc/letsencrypt/live/${HOSTNAME}/privkey.pem /opt/postfix-certs/privkey.pem
      chmod 644 /opt/postfix-certs/*.pem
  environment:
    - HOSTNAME=${HOSTNAME}
    - LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL}
    - LETSENCRYPT_SERVER=${LETSENCRYPT_SERVER:-https://acme-v02.api.letsencrypt.org/directory}
  volumes:
    - ../../../../files/cloudflare.ini:/cloudflare-secret/cloudflare.ini:ro
    - letsencrypt_data:/etc/letsencrypt
    - postfix_certs_data:/opt/postfix-certs
```

### Points clés

- **`--dns-cloudflare`** : challenge DNS-01. Certbot crée un TXT `_acme-challenge.<HOSTNAME>` via l'API Cloudflare, attend la propagation, puis Let's Encrypt le valide.
- **`--dns-cloudflare-propagation-seconds 20`** : attente avant que LE n'interroge le DNS. À augmenter si le challenge échoue.
- **`--keep-until-expiring`** : ne réémet pas si le cert existant est encore valide >30j → idempotent, pas de risque de rate limit LE.
- **`--server`** : permet de switcher staging/prod via la variable `LETSENCRYPT_SERVER`.
- **`cp -L`** : suit les symlinks de `/etc/letsencrypt/live/` vers `/etc/letsencrypt/archive/` pour copier les vrais fichiers dans le volume partagé.
- **`chmod 644`** : nécessaire pour que le user `postfix` du second conteneur (UID différent) puisse lire les certs.

### Le bind-mount Cloudflare

```yaml
- ../../../../files/cloudflare.ini:/cloudflare-secret/cloudflare.ini:ro
```

Convention **Dokploy** : les fichiers déposés via l'UI "Files/Mounts" sont stockés dans un dossier `files/` situé 4 niveaux au-dessus du `compose.yaml`. D'où les `../../../../`.

Contenu de `cloudflare.ini` :

```ini
dns_cloudflare_api_token = <token_API_avec_droits_Zone:DNS:Edit>
```

Le token Cloudflare doit avoir au minimum la permission **Zone → DNS → Edit** sur la zone du domaine.

> [!note] Warning "Unsafe permissions"
> Certbot peut afficher `Unsafe permissions on credentials configuration file`. Non bloquant — il recommande juste un `chmod 600`. Comme le fichier est en bind-mount `:ro`, on l'ignore.

### Variable `LETSENCRYPT_SERVER`

| Valeur | Quand l'utiliser |
|---|---|
| `https://acme-v02.api.letsencrypt.org/directory` | **Prod** — certs valides navigateur, rate limit strict (5 échecs/h, 50 certs/semaine) |
| `https://acme-staging-v02.api.letsencrypt.org/directory` | **Staging** — pour tester le pipeline (DNS, montage…). Certs **non reconnus** par les clients. |

> [!warning] Bascule staging → prod
> Si on a généré un cert staging, le volume `letsencrypt_data` contient déjà un cert. `--keep-until-expiring` empêchera la réémission. Solution : `docker volume rm <stack>_letsencrypt_data` avant de repasser en prod.

## Ajouts dans `postfix_sender`

```yaml
environment:
  - POSTFIX_smtpd_tls_cert_file=/etc/postfix/certs/fullchain.pem
  - POSTFIX_smtpd_tls_key_file=/etc/postfix/certs/privkey.pem
  - POSTFIX_smtpd_tls_security_level=may
volumes:
  - postfix_certs_data:/etc/postfix/certs:ro
depends_on:
  certbot:
    condition: service_completed_successfully
```

| Élément | Rôle |
|---|---|
| `POSTFIX_smtpd_tls_cert_file` / `_key_file` | Chemins vers les fichiers cert et clé dans le volume partagé |
| `POSTFIX_smtpd_tls_security_level=may` | STARTTLS **opportuniste** — le client peut négocier ou non. Mettre `encrypt` pour forcer. |
| Volume `postfix_certs_data:ro` | Lecture seule — postfix n'écrit jamais dans ce volume |
| `depends_on: service_completed_successfully` | Postfix ne démarre que si certbot s'est terminé sans erreur |

## Variables d'env (étape 2 complète)

```env
HOSTNAME=postfix.wittnerlab.com
ALLOWED_SENDER_DOMAINS=wittnerlab.com
SMTP_USER=noreply@wittnerlab.com:change_me_strong_password
LETSENCRYPT_EMAIL=jeanbaptiste.wittner@outlook.com
LETSENCRYPT_SERVER=https://acme-v02.api.letsencrypt.org/directory
```

## Tester l'envoi (avec TLS)

Ajout du flag `--ssl-reqd` qui exige STARTTLS :

```sh
curl --url 'smtp://postfix.wittnerlab.com:587' \
  --ssl-reqd \
  --mail-from 'noreply@wittnerlab.com' \
  --mail-rcpt 'jeanbaptiste.wittner@outlook.com' \
  --upload-file test_mail.txt \
  --user 'noreply@wittnerlab.com:<password>'
```

> [!check] À vérifier dans les headers du mail reçu
> - `Received: ... using TLSv1.3 ...` confirme STARTTLS côté client → relais
> - `Authentication-Results` montre `spf=pass`, `dkim=pass`, `dmarc=pass`
> - L'IP source n'est pas blacklistée (cf. mxtoolbox.com)

## Tester la délivrabilité (mail-tester.com)

[mail-tester.com](https://www.mail-tester.com/) note un mail réel (SPF, DKIM, DMARC,
reverse DNS, blacklists, contenu). C'est le test de référence avant de brancher une vraie app.

**Principe** : le site affiche une adresse **jetable** unique (ex.
`test-abc123def@srv1.mail-tester.com`). On lui envoie un mail *depuis le relais*, puis on
recharge la page pour voir le score.

> [!warning] Le port 587 n'est plus exposé
> Comme expliqué plus bas, `587` n'est joignable que depuis `messaging_net`. On ne peut donc
> **pas** `curl` depuis l'hôte/l'extérieur : on lance un conteneur `curl` jetable **attaché au
> réseau** et on vise le relais par son nom de conteneur `messaging_postfix_mail_sender:587`.

### Marche à suivre

1. Ouvrir <https://www.mail-tester.com/> et **copier l'adresse jetable** affichée.
2. Depuis le dossier `taerar/messaging/postfix/` **sur le host**, préparer le message
   (substitution de l'adresse + conversion en CRLF, cf. encart ci-dessous) puis l'envoyer
   (remplacer l'adresse jetable et le mot de passe SASL) :

```sh
MAILTESTER='test-xxxx@srv1.mail-tester.com'   # adresse jetable affichée par mail-tester

# Génère le message directement avec des CRLF (obligatoire en SMTP) — aucune
# dépendance au fichier du repo, donc pas besoin d'être dans un dossier précis.
printf 'From: "WittnerLab" <noreply@wittnerlab.com>\r\nTo: <%s>\r\nSubject: Test deliverabilite mail-tester\r\nDate: %s\r\nMessage-Id: <test-mailtester@postfix.wittnerlab.com>\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nBonjour,\r\n\r\nCeci est un mail de test via le relais Postfix postfix.wittnerlab.com.\r\n' \
  "$MAILTESTER" "$(date -R)" > /tmp/mail_mailtester.eml

docker run --rm --network messaging_net \
  -v /tmp/mail_mailtester.eml:/mail.txt:ro \
  curlimages/curl:latest \
  --url 'smtp://messaging_postfix_mail_sender:587' \
  --ssl-reqd --insecure \
  --mail-from 'noreply@wittnerlab.com' \
  --mail-rcpt "$MAILTESTER" \
  --upload-file /mail.txt \
  --user 'noreply@wittnerlab.com:<password>'
```

3. Recharger la page mail-tester → lire le score (viser **10/10**).

> [!tip] Variante « fichier du repo »
> On peut aussi partir de [`test_mail_mailtester.txt`](test_mail_mailtester.txt) (placeholder
> `MAILTESTER_ADDRESS` dans le `To:`) en se plaçant dans `taerar/messaging/postfix/`, puis en
> substituant l'adresse **et** en convertissant en CRLF avant l'envoi :
> ```sh
> CR=$(printf '\r')
> sed -e "s/<MAILTESTER_ADDRESS>/$MAILTESTER/" -e "s/\$/$CR/" \
>   test_mail_mailtester.txt > /tmp/mail_mailtester.eml
> ```

> [!warning] Fins de ligne CRLF obligatoires
> SMTP (RFC 5322) exige des en-têtes terminés par **CRLF** (`\r\n`). Le fichier `*.txt` est
> stocké en LF (propre pour le repo) ; envoyé tel quel, Postfix ne reconnaît pas la ligne vide
> qui sépare en-têtes et corps → **tous les headers sont avalés dans le corps** et SpamAssassin
> signale `MISSING_FROM/TO/SUBJECT/DATE` + `EMPTY_MESSAGE` (score ~ -8, classé spam). Le `printf`
> ci-dessus émet directement du CRLF ; la variante fichier le reconstruit via `sed`. Ne **jamais**
> committer le mot de passe SASL ni l'adresse jetable dans cette note — garder les placeholders.

> [!note] `--ssl-reqd --insecure`
> On force STARTTLS (`--ssl-reqd`) mais on **ignore la vérification du CN** (`--insecure`) :
> on se connecte par le nom de conteneur `messaging_postfix_mail_sender`, qui ne correspond pas
> au CN du cert (`postfix.wittnerlab.com`). Le chiffrement client→relais n'influence de toute
> façon pas le score mail-tester, qui juge la connexion **relais → mail-tester** (SPF/DKIM/DMARC
> du domaine `wittnerlab.com`).

## Renouvellement des certificats

Le service `certbot` ne tourne qu'au démarrage. Les certs LE expirent en **90 jours** → planifier côté Dokploy une **scheduled task hebdomadaire** :

```sh
docker compose run --rm certbot && docker compose restart postfix_sender
```

`--keep-until-expiring` rend la commande idempotente. Le `restart` est nécessaire car Postfix ne relit pas les certs à chaud.

---

## Fichiers de la stack

| Fichier | Rôle |
|---|---|
| [`compose.yaml`](compose.yaml) | Définition des services + volumes |
| [`example.env`](example.env) | Template des variables |
| [`test_mail.txt`](test_mail.txt) | Mail de test pour `curl` |
| [`test_mail_mailtester.txt`](test_mail_mailtester.txt) | Mail de test pour le score mail-tester.com |
| `../../../../files/cloudflare.ini` | Token API Cloudflare (UI Dokploy "Files/Mounts") |

---

# Brancher une app sur le relais (ex. Forgejo)

Chaque app est une **stack Compose séparée** ; pour qu'elle résolve le conteneur
`messaging_postfix_mail_sender` par son nom, elle doit partager un **réseau Docker externe**
avec Postfix (même convention que `security_network` / `monitoring_net`).

```bash
# À créer une seule fois sur le host, avant de lancer les stacks :
docker network create messaging_net
```

> [!warning] Relais interne uniquement
> Le port `587` n'est **plus publié sur l'hôte** (`ports:` retiré du `compose.yaml`). Le relais
> n'est joignable que depuis le réseau Docker `messaging_net`. Les tests `curl` des étapes 1 et 2
> ci-dessous (qui visent `postfix.wittnerlab.com:587` depuis l'extérieur) ne fonctionnent donc plus
> tels quels — il faudrait réexposer temporairement le port, ou tester depuis un conteneur du réseau
> (ex. `docker exec source_control_forgejo_server ...`).

`mail_sender` est attaché à `messaging_net` (déclaré `external: true` dans `compose.yaml`).
Côté app, il suffit de :

1. Rejoindre `messaging_net` (déclaré `external: true`).
2. Pointer le client SMTP sur `messaging_postfix_mail_sender:587` en `smtp+starttls`.
3. S'authentifier avec un user présent dans `SMTP_USER` (cf. `example.env`).
4. Comme on se connecte par nom de conteneur (≠ CN du cert `postfix.wittnerlab.com`), faire
   **confiance au cert interne** côté client (pour Forgejo : `FORGEJO__mailer__FORCE_TRUST_SERVER_CERT: true`).

> Forgejo (`source-control/forgejo`) utilise un user SASL dédié `forgejo-noreply@wittnerlab.com` —
> il doit exister dans `SMTP_USER` ici **et** correspondre à `MAIL_USER`/`MAIL_PASSWD` côté Forgejo.

## Historique des décisions

- **2026-05-08** — Migration de `/etc/letsencrypt:/etc/letsencrypt:ro` (bind hôte) vers une stack autonome avec service `certbot` intégré. Motivation : portabilité Dokploy.
- **2026-05-08** — Choix DNS-01 Cloudflare plutôt que HTTP-01 : port 80 non exposé sur le host + ouverture future aux wildcards.
- **2026-05-08** — Bind-mount `cloudflare.ini` plutôt que volume nommé : compatible "Files/Mounts" Dokploy.
- **2026-05-08** — Ajout de `LETSENCRYPT_SERVER` paramétrable suite à un incident LE prod (le staging a permis de débloquer les tests).

## Ressources

- [Dokploy docs](https://dokploy.com/)
- [Image boky/postfix](https://github.com/bokysan/docker-postfix)
- [Certbot dns-cloudflare plugin](https://certbot-dns-cloudflare.readthedocs.io/)
- [Statut Let's Encrypt](https://letsencrypt.status.io/)
- [Cloudflare API tokens](https://dash.cloudflare.com/profile/api-tokens)
