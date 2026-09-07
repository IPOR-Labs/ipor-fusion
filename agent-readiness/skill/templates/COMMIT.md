# Txx — commit do wykonania ręcznie na hoście

## Komunikat

```
<subject z linii **Commit** w PLAN.md, dosłownie>

<2–6 linii: co zmieniono, jak zweryfikowano, czego nie dało się sprawdzić>
```

Ten sam tekst jest w `agent-readiness/tasks/Txx/commit-message.txt`.

## Pliki należące do tego commita

| Plik | Zmiana |
| --- | --- |
| `agent-readiness/PLAN.md` | checkbox Txx → `[x]` |
| `agent-readiness/STATUS.md` | wiersz Txx → ready-for-commit |
| `agent-readiness/tasks/Txx/LOG.md` | nowy |
| `agent-readiness/tasks/Txx/COMMIT.md` | nowy |
| `agent-readiness/tasks/Txx/commit-message.txt` | nowy |
| `<ścieżka>` | nowy / zmieniony / usunięty — <co> |

## Pliki w `git status`, które NIE należą do tego commita

<lista albo „brak" — to cudze zmiany, nie dodawać>

## Komendy dla hosta

```bash
cd <repo root>
git add agent-readiness/PLAN.md agent-readiness/STATUS.md agent-readiness/tasks/Txx/
git add <plik1> <plik2> …
git status --short          # sprawdź, że staged są tylko pliki z tabeli
git commit -F agent-readiness/tasks/Txx/commit-message.txt
```

Po commicie: w `agent-readiness/STATUS.md` zmień wiersz Txx na `committed <hash>` (albo zrobi to
następny agent w kroku 0 skilla).
