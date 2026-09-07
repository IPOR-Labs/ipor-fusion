# BOOTSTRAP — commit startowy katalogu agent-readiness

## Komunikat

Treść w `agent-readiness/tasks/BOOTSTRAP/commit-message.txt`
(subject: `docs(agents): split readiness plan into atomic tasks`).

## Pliki należące do tego commita

| Plik | Zmiana |
| --- | --- |
| `agent-readiness/README.md` | nowy — opis procesu |
| `agent-readiness/PLAN.md` | nowy — plan (przeniesiony z `AI_AGENT_READINESS_PLAN.md`, linki poprawione na `../`) |
| `agent-readiness/STATUS.md` | nowy — tabela statusów T00–T52 |
| `agent-readiness/ENVIRONMENT.md` | nowy — fakty o środowisku |
| `agent-readiness/skill/SKILL.md` | nowy — skill `readiness-task` |
| `agent-readiness/skill/templates/LOG.md` | nowy |
| `agent-readiness/skill/templates/COMMIT.md` | nowy |
| `agent-readiness/tasks/BOOTSTRAP/COMMIT.md` | nowy (ten plik) |
| `agent-readiness/tasks/BOOTSTRAP/commit-message.txt` | nowy |

Symlink `.claude/skills/readiness-task` jest lokalny (`.claude/` w `.gitignore`) — nie commitować.

## Pliki w `git status`, które NIE należą do tego commita

brak (stan przy tworzeniu: tylko `?? agent-readiness/`)

## Komendy dla hosta

```bash
cd /Users/piotrrzonsowski/repos/ipor-fusion
git add agent-readiness/
git status --short          # oczekiwane: tylko A agent-readiness/...
git commit -F agent-readiness/tasks/BOOTSTRAP/commit-message.txt
```
