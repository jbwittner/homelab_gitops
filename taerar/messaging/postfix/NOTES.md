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

Avec `DKIM_AUTOGENERATE=true`, la clé est générée au 1er démarrage dans
`/etc/opendkim/keys/<domain>.private` (+ `.txt` pour la partie publique), selector par défaut
`mail`. Il faut publier la partie publique :

```sh
docker exec messaging_postfix_mail_sender cat /etc/opendkim/keys/wittnerlab.com.txt
```

Puis créer un TXT en DNS :

```
mail._domainkey.wittnerlab.com  TXT  "v=DKIM1; h=sha256; k=rsa; s=email; p=MIIBIj..."
```

> [!important] En prod cette stack utilise une **clé figée** (`DKIM_AUTOGENERATE=false` +
> bind-mount), pas l'autogénération. Voir [§ Figer la clé DKIM](#figer-la-clé-dkim-anti-régénération-dns)
> pour le pourquoi et la procédure.

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

# Tester la délivrabilité

Deux outils complémentaires, tous deux à lancer **depuis un conteneur attaché à `messaging_net`**
(le port `587` n'est plus exposé sur l'hôte) :

| Outil | Ce qu'il mesure | Limite |
|---|---|---|
| [mail-tester.com](https://www.mail-tester.com/) | Score SpamAssassin + SPF/DKIM/DMARC/PTR/blacklists/contenu | ~3 tests/jour gratuits par IP |
| [mailreach.co](https://www.mailreach.co/) | **Placement réel** inbox vs spam/promotions chez Gmail/Outlook/Yahoo… | compte requis ; envoi vers une liste de seeds |

> [!note] Contraintes d'envoi communes
> Les deux tests partagent le **CRLF obligatoire** et le `--ssl-reqd --insecure` (connexion par
> nom de conteneur) — détaillés dans « Notes communes aux deux tests » en bas de cette section.

## 1. mail-tester.com (score SpamAssassin — limité en requêtes)

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

## 2. mailreach.co (placement inbox vs spam, multi-fournisseurs)

[mailreach.co](https://www.mailreach.co/) ne donne pas un simple score : il dépose des
**adresses-pièges (seeds)** chez les principaux fournisseurs et mesure où atterrit réellement le
mail (boîte de réception, spam, onglet promotions). Le principe MailReach :

1. MailReach affiche un **code unique** à insérer **n'importe où** dans le mail (sujet ou corps).
2. Il fournit une **liste d'adresses seed** auxquelles envoyer ce mail.
3. Après l'envoi, cliquer sur « Check placement » → rapport de placement par fournisseur.

### Marche à suivre

1. Sur MailReach (*Spam Test* → nouveau test), copier le **code** et la **liste d'adresses**.
2. Sur le host, envoyer **un seul** mail contenant le code à **toutes** les adresses (un
   `--mail-rcpt` par adresse de la liste) :

```sh
CODE='mailreach-xxxxxxxxxxxx'          # code fourni par MailReach (à mettre dans le mail)

# Colle la liste de seeds MailReach telle quelle : virgules, espaces ET retours
# à la ligne sont tolérés (on normalise juste après).
RAW='seed1@gmail.com, seed2@outlook.com
seed3@yahoo.fr'

# Le code MailReach doit apparaître quelque part dans le mail → ici dans le corps.
printf 'From: "WittnerLab" <noreply@wittnerlab.com>\r\nTo: <undisclosed-recipients:;>\r\nSubject: Test deliverabilite WittnerLab\r\nDate: %s\r\nMessage-Id: <mailreach-%s@postfix.wittnerlab.com>\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nBonjour,\r\n\r\nCeci est un mail de test de delivrabilite via le relais postfix.wittnerlab.com.\r\n\r\n%s\r\n' \
  "$(date -R)" "$RANDOM" "$CODE" > /tmp/mail_mailreach.eml

# Un --mail-rcpt par adresse — virgules et CR (\r de Windows) convertis en espaces,
# puis word-splitting. Évite le « 501 Bad recipient address syntax ».
rcpt_args=()
for r in $(printf '%s' "$RAW" | tr ',\r' '  '); do
  rcpt_args+=(--mail-rcpt "$r")
done
printf 'Destinataires: %s\n' "${rcpt_args[*]}"   # vérifier la liste AVANT d'envoyer

docker run --rm --network messaging_net \
  -v /tmp/mail_mailreach.eml:/mail.txt:ro \
  curlimages/curl:latest \
  --url 'smtp://messaging_postfix_mail_sender:587' \
  --ssl-reqd --insecure \
  --mail-from 'noreply@wittnerlab.com' \
  "${rcpt_args[@]}" \
  --upload-file /mail.txt \
  --user 'noreply@wittnerlab.com:<password>'
```

3. Revenir sur MailReach → « Check placement » → lire le rapport (viser **Inbox** partout).

> [!tip] Bash requis (`rcpt_args` est un tableau)
> L'expansion `"${rcpt_args[@]}"` est du **bash**. Sur le host Dokploy (root, bash) c'est bon ;
> en `sh` pur, écrire les `--mail-rcpt` à la main, un par adresse. Le `printf 'Destinataires…'`
> affiche la liste construite : **vérifie-la** avant d'envoyer (chaque adresse seule, sans
> virgule ni espace parasite) — c'est ce qui évite le `501 Bad recipient address syntax`.

> [!note] Un seul envoi, plusieurs destinataires
> On envoie **un unique** message (un seul `DATA`) avec plusieurs `RCPT TO` — c'est exactement ce
> qu'attend MailReach (un seul send vers toute la liste de seeds). Le `To:` est mis à
> `undisclosed-recipients:;` pour ne pas exposer la liste ; MailReach ne lit que le **code**.

## Notes communes aux deux tests

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
> façon pas le résultat de ces tests, qui jugent la connexion **relais → destinataire**
> (SPF/DKIM/DMARC du domaine `wittnerlab.com`).

## Renouvellement des certificats

Le service `certbot` ne tourne qu'au démarrage. Les certs LE expirent en **90 jours** → planifier côté Dokploy une **scheduled task hebdomadaire** :

```sh
docker compose run --rm certbot && docker compose restart postfix_sender
```

`--keep-until-expiring` rend la commande idempotente. Le `restart` est nécessaire car Postfix ne relit pas les certs à chaud.

---

## Figer la clé DKIM (anti-régénération DNS)

> [!danger] Piège vécu (2026-06-14)
> `DKIM_AUTOGENERATE=true` régénère une **nouvelle** paire de clés dès que le volume des clés
> est vide (recréation du volume lors d'un redéploiement, `down -v`, migration de host…).
> La clé privée change mais le TXT DNS reste l'ancien → SpamAssassin renvoie **`DKIM_INVALID`**
> (signature présente mais invalide). Diagnostic : comparer le `p=` des deux côtés.
> ```sh
> # Clé réellement chargée par le conteneur
> docker exec messaging_postfix_mail_sender cat /etc/opendkim/keys/wittnerlab.com.txt
> # Clé publiée en DNS
> dig +short TXT mail._domainkey.wittnerlab.com
> ```
> Si les `p=` diffèrent → republier en DNS le `p=` du conteneur (un seul bloc, sans guillemets).

**Fix durable adopté :** sortir DKIM du cycle de vie d'un volume Docker. La clé est fournie via
un **bind-mount Dokploy "Files/Mounts"** (même convention que `cloudflare.ini`) et
`DKIM_AUTOGENERATE=false` — la clé ne change donc plus jamais, quel que soit le sort des volumes.

```yaml
# compose.yaml — service mail_sender
environment:
  - ENABLE_OPENDKIM=true
  - DKIM_AUTOGENERATE=false
volumes:
  - ../../../../files/opendkim-keys:/etc/opendkim/keys   # RW : boky chown/chmod au démarrage
```

### Procédure (déposer la clé sur un nouvel hôte / 1ère mise en place)

1. **Récupérer la clé actuelle** depuis le conteneur en marche (clé privée + publique) :
   ```sh
   docker exec messaging_postfix_mail_sender cat /etc/opendkim/keys/wittnerlab.com.private
   docker exec messaging_postfix_mail_sender cat /etc/opendkim/keys/wittnerlab.com.txt
   ```
2. Dans l'UI Dokploy **"Files/Mounts"** de la stack, créer deux fichiers sous le dossier
   `opendkim-keys/` (→ stockés dans `.../<stack>/files/opendkim-keys/`) :
   - `opendkim-keys/wittnerlab.com.private` (contenu de la clé privée)
   - `opendkim-keys/wittnerlab.com.txt` (contenu de la clé publique)
3. Redéployer. L'entrypoint boky scanne `/etc/opendkim/keys/*.private`, régénère `KeyTable`/
   `SigningTable` (selector `mail`) et `chown opendkim` les fichiers (d'où le mount **RW**).
4. Vérifier que DNS (`mail._domainkey.wittnerlab.com`) publie bien le `p=` de cette clé, puis
   retester sur mail-tester → `DKIM_VALID`.

> [!warning] Ne jamais committer la clé privée
> Comme `cloudflare.ini`, la clé vit dans le dossier `files/` de Dokploy (hors du checkout git
> `code/`), pas dans le repo. Le repo ne contient que la **référence** au bind-mount.

---

## Fichiers de la stack

| Fichier | Rôle |
|---|---|
| [`compose.yaml`](compose.yaml) | Définition des services + volumes |
| [`example.env`](example.env) | Template des variables |
| [`test_mail.txt`](test_mail.txt) | Mail de test pour `curl` |
| [`test_mail_mailtester.txt`](test_mail_mailtester.txt) | Mail de test pour le score mail-tester.com |
| `../../../../files/cloudflare.ini` | Token API Cloudflare (UI Dokploy "Files/Mounts") |
| `../../../../files/opendkim-keys/` | Clé DKIM figée `wittnerlab.com.{private,txt}` (UI Dokploy "Files/Mounts") |

---

# Brancher une app sur le relais (Forgejo, authentik, …)

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
4. **Le cert TLS et le nom de connexion.** Le relais présente un cert Let's Encrypt dont le CN
   est `postfix.wittnerlab.com`. Deux familles de clients :

| App | User SASL dédié | Hôte SMTP à utiliser | Vérif. du cert |
|---|---|---|---|
| **Forgejo** (`source-control/forgejo`) | `forgejo-noreply@wittnerlab.com` | `messaging_postfix_mail_sender:587` | tolère le mismatch via `FORGEJO__mailer__FORCE_TRUST_SERVER_CERT: true` |
| **authentik** (`authentication/authentik`) | `authentik-noreply@wittnerlab.com` | **`postfix.wittnerlab.com:587`** (alias réseau) | **vérifie** le cert → impose CN + CA valides (voir ci-dessous) |

> [!important] authentik vérifie le certificat (alias réseau obligatoire)
> Contrairement à curl (`--insecure`) ou Forgejo (`FORCE_TRUST_SERVER_CERT`), **authentik valide
> le cert TLS** et n'expose pas d'option pour le désactiver. Si on le pointe sur le **nom de
> conteneur** `messaging_postfix_mail_sender`, le STARTTLS échoue avec
> `SSL alert number 42 (bad_certificate)` (le CN du cert ≠ le nom utilisé). Solution : le conteneur
> `mail_sender` porte un **alias réseau `postfix.wittnerlab.com`** (= CN du cert) sur `messaging_net` —
> on y connecte authentik par ce nom, et Docker le résout vers le conteneur en interne. Deux
> conditions pour que la validation passe :
> 1. **CN** : utiliser `postfix.wittnerlab.com` (l'alias), pas le nom de conteneur.
> 2. **CA** : le cert doit être un Let's Encrypt **prod** (un cert *staging* a une CA non reconnue
>    → `bad_certificate` quand même). Vérifier : `LETSENCRYPT_SERVER` = prod.

Chaque user SASL doit exister dans `SMTP_USER` (postfix `example.env`) **et** correspondre aux
identifiants côté app (`MAIL_USER`/`MAIL_PASSWD` pour Forgejo, `MAILER_USER`/`MAILER_PASSWD` pour
authentik).

> [!example] authentik (`authentication/authentik`)
> `server` **et** `worker` rejoignent `messaging_net` (+ `authentik_net` interne) et pointent sur
> le relais via les variables (`example.env`) :
> ```env
> MAILER_SMTP_ADDR=postfix.wittnerlab.com    # alias réseau (= CN du cert), PAS le nom de conteneur
> MAILER_SMTP_PORT=587
> MAILER_USER=authentik-noreply@wittnerlab.com
> MAILER_PASSWD=<mot de passe SASL authentik>
> MAILER_FROM=authentik@wittnerlab.com
> ```
> côté compose : `AUTHENTIK_EMAIL__USE_TLS=true` (STARTTLS), `USE_SSL=false`. Le `From`
> (`authentik@wittnerlab.com`) doit être dans `ALLOWED_SENDER_DOMAINS` (`wittnerlab.com`). ✔

## Historique des décisions

- **2026-05-08** — Migration de `/etc/letsencrypt:/etc/letsencrypt:ro` (bind hôte) vers une stack autonome avec service `certbot` intégré. Motivation : portabilité Dokploy.
- **2026-05-08** — Choix DNS-01 Cloudflare plutôt que HTTP-01 : port 80 non exposé sur le host + ouverture future aux wildcards.
- **2026-05-08** — Bind-mount `cloudflare.ini` plutôt que volume nommé : compatible "Files/Mounts" Dokploy.
- **2026-05-08** — Ajout de `LETSENCRYPT_SERVER` paramétrable suite à un incident LE prod (le staging a permis de débloquer les tests).
- **2026-06-14** — Test mail-tester : score initial ~ -8 (headers avalés car mail en LF) corrigé en envoyant le message en CRLF + Message-Id. Puis `DKIM_INVALID` dû à une clé DNS désynchronisée (clé régénérée par le volume). Décision : **figer la clé DKIM** via bind-mount `files/opendkim-keys/` + `DKIM_AUTOGENERATE=false` (suppression du volume `dkim_data`), sur le modèle de `cloudflare.ini`.
- **2026-06-14** — Branchement d'**authentik** sur le relais : `server`/`worker` rejoignent `messaging_net`, user SASL dédié `authentik-noreply@wittnerlab.com`. authentik **vérifie** le cert (STARTTLS → `SSL alert 42 bad_certificate` quand on vise le nom de conteneur). Solution : alias réseau `postfix.wittnerlab.com` (= CN du cert) sur `mail_sender`, et authentik pointe `MAILER_SMTP_ADDR=postfix.wittnerlab.com`. Nécessite un cert LE **prod** (staging = CA non reconnue).

## Ressources

- [Dokploy docs](https://dokploy.com/)
- [Image boky/postfix](https://github.com/bokysan/docker-postfix)
- [Certbot dns-cloudflare plugin](https://certbot-dns-cloudflare.readthedocs.io/)
- [Statut Let's Encrypt](https://letsencrypt.status.io/)
- [Cloudflare API tokens](https://dash.cloudflare.com/profile/api-tokens)
