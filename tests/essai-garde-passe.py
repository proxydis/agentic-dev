"""Essai de garde-passe.py (hook PreToolUse des passes de voie et de relecture de FIN) : ce qu'il refuse, ce qu'il laisse
passer. Sans réseau ni Claude : le JSON du hook est donné sur stdin, comme Claude Code le fait.
  python3 tests/essai-garde-passe.py      (sortie 0 = tout passe)
"""
import json
import os
import subprocess
import sys
import tempfile

GARDE = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "garde-passe.py")
echecs = 0


def garde(evenement, env=None):
    p = subprocess.run([sys.executable, "-I", GARDE], input=json.dumps(evenement), capture_output=True, text=True,
                       env={**os.environ, **(env or {})})
    return p.returncode, p.stderr


def verifier(cond, texte):
    global echecs
    print(("  ok   " if cond else "  ÉCHEC ") + texte)
    echecs += 0 if cond else 1


with tempfile.TemporaryDirectory() as d:
    os.makedirs(os.path.join(d, "tests", "unit"))

    def bash(cmd, fond=False, env=None):
        entree = {"command": cmd}
        if fond:
            entree["run_in_background"] = True
        return garde({"tool_name": "Bash", "tool_input": entree, "cwd": d}, env)

    print("refusés (code 2, raison sur stderr)")
    for cmd, texte in [
        ("uv run pytest -q", "pytest sans fichier : suite entière"),
        (".venv/bin/pytest -n 4 -q", "pytest sans fichier, options à valeur sautées"),
        ("python -m pytest tests/test_calcul*.py", "motif"),
        ("pytest tests/unit -q", "dossier de tests"),
        ("cd front && pnpm vitest run", "vitest sans fichier"),
        ("npx vitest run tests/unit/", "vitest sur un dossier"),
        ("pytest " + " ".join(f"t{i}.py" for i in range(26)), "26 fichiers (plafond 25)"),
        ("ruff check . && pytest -x", "suite entière après un autre outil"),
    ]:
        rc, err = bash(cmd)
        verifier(rc == 2 and "Refusé par le garde" in err, f"{texte} : `{cmd[:50]}`")
    rc, err = bash("pytest tests/test_a.py", fond=True)
    verifier(rc == 2 and "arrière-plan" in err, "commande en arrière-plan")
    for outil in ("Task", "Agent", "Monitor"):
        rc, _ = garde({"tool_name": outil, "tool_input": {}, "cwd": d})
        verifier(rc == 2, f"outil de fond {outil}")
    rc, _ = bash("pytest " + " ".join(f"t{i}.py" for i in range(6)), env={"GARDE_MAX_FICHIERS": "5"})
    verifier(rc == 2, "plafond réglé par GARDE_MAX_FICHIERS (6 fichiers pour 5)")

    print("acceptés (code 0)")
    for cmd, texte in [
        ("pytest tests/test_a.py tests/test_b.py::test_x -n 4 -q", "fichiers nommés, un test nommé"),
        ("pytest -k calcul tests/test_a.py", "option -k avec valeur, puis un fichier"),
        ("pytest $(cat liste.txt)", "liste calculée"),
        ("pnpm vitest run src/a.test.ts --maxWorkers=2", "vitest sur un fichier"),
        ("ruff check . && mypy app", "aucun lanceur de tests"),
        ("pytest tests/test_a.py > sortie.txt 2>&1", "redirection après le fichier"),
        ("pytest " + " ".join(f"t{i}.py" for i in range(25)), "25 fichiers"),
    ]:
        rc, err = bash(cmd)
        verifier(rc == 0, f"{texte} : `{cmd[:50]}`" + (f" ({err.strip()[:80]})" if rc else ""))
    rc, _ = garde({"tool_name": "Read", "tool_input": {"file_path": "x"}, "cwd": d})
    verifier(rc == 0, "autre outil que Bash")
    p = subprocess.run([sys.executable, "-I", GARDE], input="pas du json", capture_output=True, text=True)
    verifier(p.returncode == 0, "entrée illisible : laissée passer")

print()
print("TOUT PASSE" if not echecs else f"{echecs} échec(s)")
sys.exit(1 if echecs else 0)
