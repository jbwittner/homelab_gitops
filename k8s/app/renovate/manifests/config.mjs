// Configuration GLOBALE du bot `renovate-github` (`RENOVATE_CONFIG_FILE`), montée par le
// ConfigMap `renovate-github-config` (configMapGenerator de `kustomization.yaml`).
//
// Son seul rôle : authentifier Renovate comme **GitHub App**. La CLI Renovate ne sait pas le faire
// seule — elle n'accepte pas un couple App ID + clé privée, seulement un jeton d'installation
// `ghs_…`, valable 1 h (cf. https://docs.renovatebot.com/modules/platform/github/). Ce module le
// produit à chaque run, avant que Renovate ne démarre :
//
//   1. signe un JWT RS256 avec la clé privée de l'App (10 min max, imposé par GitHub) ;
//   2. POST /app/installations/<id>/access_tokens → jeton d'installation (1 h).
//
// Le reste découle du préfixe `ghs_` du jeton : Renovate se sait alors GitHub App, déduit seul
// son `gitAuthor` (`<slug>[bot] <<id>+<slug>[bot]@users.noreply.github.com>`) et, en
// autodiscover, liste les dépôts de l'INSTALLATION (`/installation/repositories`).
//
// Ça marche parce que Renovate charge ce fichier par `import()` : un module ESM, donc le
// top-level await est permis, et Renovate attend le résultat avant de lire `token`.
//
// ⚠️ Rien ici ne doit être surchargé par l'environnement : Renovate fait primer les variables
// `RENOVATE_*` sur ce fichier. Un `RENOVATE_TOKEN` remis dans le CronJob écraserait
// silencieusement le jeton calculé ici. Idem pour `RENOVATE_GIT_AUTHOR` : il remplacerait
// l'identité déduite de l'App.
//
// ⚠️ 1 h de validité suffit largement (un run dure ~3 min), mais le jeton n'est PAS renouvelé en
// cours de run : un run qui dépasserait l'heure finirait en 401.
//
// Pas de `RENOVATE_GITHUB_COM_TOKEN` : la plateforme étant github.com, Renovate réutilise ce
// jeton pour les lookups de releases (changelogs, `github-releases`, `github-tags`).

import { createPrivateKey, createSign } from 'node:crypto';
import { readFileSync } from 'node:fs';

// Montage du Secret `renovate-github` (volume, pas `envFrom` — la clé privée ne passe pas par
// l'environnement du process).
const SECRET_DIR = '/etc/renovate-github-app';
const API = 'https://api.github.com';

const read = (name) => readFileSync(`${SECRET_DIR}/${name}`, 'utf8').trim();

async function gh(method, path, bearer) {
  const res = await fetch(`${API}${path}`, {
    method,
    headers: {
      Accept: 'application/vnd.github+json',
      Authorization: `Bearer ${bearer}`,
      'User-Agent': 'renovate-bleu-kalecgos',
      'X-GitHub-Api-Version': '2022-11-28',
    },
    signal: AbortSignal.timeout(30_000),
  });
  if (!res.ok) {
    throw new Error(`${method} ${path} → HTTP ${res.status} ${await res.text()}`);
  }
  return res.json();
}

function appJwt(appId, privateKey) {
  const b64 = (obj) => Buffer.from(JSON.stringify(obj)).toString('base64url');
  const now = Math.floor(Date.now() / 1000);
  // `iat` reculé de 60 s : tolère une horloge du nœud légèrement en avance sur celle de GitHub.
  // `exp` à 9 min : GitHub refuse au-delà de 10.
  const unsigned = `${b64({ alg: 'RS256', typ: 'JWT' })}.${b64({ iat: now - 60, exp: now + 540, iss: appId })}`;
  const signature = createSign('RSA-SHA256').update(unsigned).sign(privateKey, 'base64url');
  return `${unsigned}.${signature}`;
}

let config;
try {
  const jwt = appJwt(read('app-id'), createPrivateKey(read('private-key.pem')));
  const { token } = await gh('POST', `/app/installations/${read('installation-id')}/access_tokens`, jwt);
  config = { token };
} catch (err) {
  // Sans ce catch, Renovate n'affiche qu'un « Error parsing config file » sans la cause (elle
  // part en niveau debug). Ici l'erreur réelle sort en clair dans `kubectl logs`.
  console.error(`renovate-github : authentification GitHub App impossible — ${err.message}`);
  process.exit(1);
}

export default config;
