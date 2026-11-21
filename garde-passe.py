#!/usr/bin/env python3
"""Garde des passes Claude du cycle de lot (hook PreToolUse posé par run-lot.sh, passes de voie et relecture de FIN).

Refuse, avant qu'elles ne partent :
- toute tâche de fond (Bash `run_in_background`, outils Task/Agent/Monitor) : la passe attendait ses notifications
  pendant des dizaines de minutes ;
- toute suite large de tests : pytest ou vitest sans fichier (suite entière), avec un motif (`test_calcul*.py`), sur
  un dossier, ou sur plus de GARDE_MAX_FICHIERS fichiers (25 par défaut). La suite complète est jouée une seule fois,
  en script, par la partie mécanique de la fin de lot (fin-mecanique.sh) ; une relecture de fin qui la joue elle-même,
  en arrière-plan, peut y passer l'essentiel de sa durée, avant que la partie mécanique ne la rejoue.
Une liste calculée (`$(cat …)`, `$F`) passe : illisible ici, elle reste sous la règle écrite du cadre.

Entrée : le JSON du hook sur stdin. Refus : code 2, raison sur stderr (Claude la lit et adapte sa commande).
Réglages (environnement) : GARDE_MAX_FICHIERS. run-lot.sh pose le hook (GARDE_PASSE=0 pour l'ôter).
"""
import json
import os
import re
import shlex
import sys

MAX_FICHIERS = int(os.environ.get("GARDE_MAX_FICHIERS", "25"))
FOND = {"Task", "Agent", "Monitor"}
# options de pytest / vitest qui prennent une valeur séparée
AVEC_VALEUR = {"-n", "-k", "-m", "-p", "-o", "-c", "-W", "--basetemp", "--dist", "--deselect", "--ignore",
               "--rootdir", "--timeout", "--maxfail", "--junitxml", "--durations", "--tb", "-r", "--reporter",
               "--maxWorkers", "--project", "--config", "--dir", "-t", "--testNamePattern", "--pool"}


def refuse(raison: str) -> None:
    print(f"Refusé par le garde du cycle de lot : {raison}", file=sys.stderr)
    sys.exit(2)


def segments(cmd: str):
    # découpe grossière aux séparateurs du shell, suffisante pour repérer un lancement de tests
    return [s for s in re.split(r"&&|\|\||;|\||\n", cmd) if s.strip()]


def args_de_tests(seg: str):
    try:
        toks = shlex.split(seg, comments=True)
    except ValueError:
        toks = seg.split()
    for i, t in enumerate(toks):
        base = os.path.basename(t)
        if base in ("pytest", "py.test") or (t == "pytest" and i and toks[i - 1] == "-m"):
            outil, reste = "pytest", toks[i + 1:]
            break
        if base == "vitest":
            outil, reste = "vitest", toks[i + 1:]
            if reste and reste[0] in ("run", "related"):
                reste = reste[1:]
            break
    else:
        return None
    chemins, saute = [], False
    for t in reste:
        if saute:
            saute = False
            continue
        if t.startswith("-"):
            saute = t in AVEC_VALEUR
            continue
        if t.startswith((">", "<", "2>")) or re.match(r"^\d?>", t):
            break
        chemins.append(t)
    return outil, chemins


def controle(cmd: str, cwd: str) -> None:
    for seg in segments(cmd):
        r = args_de_tests(seg)
        if not r:
            continue
        outil, chemins = r
        if any("$" in c or "`" in c for c in chemins):
            continue  # liste calculée ($(cat …), $F) : illisible ici, laissée au cadre écrit
        if not chemins:
            refuse(f"{outil} sans fichier de test lance toute la suite. Elle est jouée en script après la passe ; "
                   "ici, nomme les fichiers de test des modules touchés.")
        fichiers = 0
        for c in chemins:
            p = c.split("::")[0]
            if any(ch in p for ch in "*?["):
                refuse(f"motif `{c}` : une liste par motif est une suite large. Nomme les fichiers un par un "
                       f"(au plus {MAX_FICHIERS}), ceux des modules touchés et de leurs importateurs directs.")
            if os.path.isdir(os.path.join(cwd, p)):
                refuse(f"dossier `{c}` : une passe ne lance pas un dossier de tests entier. Nomme les fichiers "
                       f"(au plus {MAX_FICHIERS}).")
            fichiers += 1
        if fichiers > MAX_FICHIERS:
            refuse(f"{fichiers} fichiers de test : au plus {MAX_FICHIERS} dans une passe. La suite large est jouée "
                   "en script après la passe ; garde les fichiers des modules que tu touches.")


def main() -> None:
    try:
        ev = json.load(sys.stdin)
    except Exception:
        return
    outil = ev.get("tool_name", "")
    entree = ev.get("tool_input") or {}
    if outil in FOND:
        refuse(f"outil {outil} : pas de tâche ni de sous-agent en arrière-plan dans une passe du cycle de lot.")
    if outil != "Bash":
        return
    if entree.get("run_in_background"):
        refuse("pas de commande en arrière-plan dans une passe du cycle de lot. Lance-la au premier plan, "
               "sur des tests ciblés.")
    controle(entree.get("command", ""), ev.get("cwd") or os.getcwd())


if __name__ == "__main__":
    main()
