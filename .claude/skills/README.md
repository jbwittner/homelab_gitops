# Skills projet

Skills Claude Code propres à ce repo (`.claude/skills/<name>/SKILL.md`).

| Skill | Usage | Description |
|---|---|---|
| [`check-regles`](check-regles/SKILL.md) | `/check-regles <dossier>` | Audit read-only d'un dossier contre les règles de `doc/` (GitOps, conventions, réseau). Rapporte les violations, ne modifie rien. |

Les règles vérifiées vivent dans [doc/](../../doc/) — un skill relit ces fichiers à chaque
exécution, rien n'est codé en dur.
