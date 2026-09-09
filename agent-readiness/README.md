# agent-readiness — plan i proces przygotowania repo dla agentów AI

Ten katalog trzyma wszystko, co dotyczy planu „IPOR Fusion przyjazne agentom": sam plan, skill
do wykonywania zadań, status oraz dokumentację i przygotowane commity każdego zadania.

## Pliki

| Plik | Rola |
| --- | --- |
| [PLAN.md](PLAN.md) | Plan: sekcje 1–8 projekt docelowy, sekcja 9 lista zadań `T00`–`T52`, sekcja 10 pomiar. |
| [STATUS.md](STATUS.md) | Tabela statusów zadań. Jedyne miejsce, gdzie sprawdzasz, co jest zrobione. |
| [ENVIRONMENT.md](ENVIRONMENT.md) | Zweryfikowane fakty o maszynie: read-only `.git` w VM, RPC, wersje narzędzi. |
| [INTEGRATIONS-TODO.md](INTEGRATIONS-TODO.md) | Lista wszystkich integracji (fuse'y, reward fuse'y) do skatalogowania po T52, z priorytetami i definicją „zrobione”. |
| [skill/SKILL.md](skill/SKILL.md) | Skill `readiness-task` (Claude Code) — procedura wykonania jednego zadania. |
| [skill/templates/](skill/templates/) | Szablony `LOG.md` i `COMMIT.md`, obowiązkowe dla każdego zadania. |
| `tasks/Txx/` | Dokumentacja wykonania zadania: `LOG.md` (kroki, weryfikacja), `COMMIT.md` + `commit-message.txt` (gotowy commit), dowody. |

## Proces

```
Pete: „zrób T05"  →  agent (skill readiness-task)
   0. uzgadnia STATUS.md z git log
   1. czyta blok T05 w PLAN.md, sprawdza zależności
   2. implementuje wyłącznie zakres
   3. wykonuje kryteria odbioru, zapisuje komendy i wyniki
   4. pisze tasks/T05/LOG.md, COMMIT.md, commit-message.txt
   5. STATUS.md → ready-for-commit, PLAN.md checkbox → [x]
   6. raportuje i STOP
Pete: przegląda diff + COMMIT.md, commituje na hoście komendami z COMMIT.md
      (opcjonalnie) STATUS.md → committed <hash>
```

Agent **nigdy** nie commituje — w VM `.git` jest read-only, a Pete chce zatwierdzać każdy commit.

## Uruchomienie skilla

Skill jest podlinkowany z `.claude/skills/readiness-task` (symlink do `agent-readiness/skill`;
`.claude/` jest gitignore'owany, więc na nowej maszynie odtwórz link:
`ln -s ../../agent-readiness/skill .claude/skills/readiness-task`).

```
/readiness-task T05
```

albo po prostu „zrób zadanie T05 z planu agent-readiness". Działa z Opus/Sonnet — skill jest
napisany jako procedura z twardymi regułami, nie wymaga kontekstu z tej rozmowy.

## Kolejność startowa

Rekomendacja po weryfikacji repo (2026-09-07): `T01 → T02 → T05 → T07 → T03 → T04 → T08`, czyli
małe, niezależne commity dokumentacyjno-buildowe. `T00` (pomiar bazowy) nie blokuje niczego poza
`T48` i jest kosztowny, więc może pójść równolegle lub później. Etap fabryki (`T20+`) wymaga
zgody na użycie MCP `fusion_address_lookup`.
