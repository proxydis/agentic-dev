#!/usr/bin/env python3
"""Banc d'essai de cycle-lot : un cycle complet et les cas de refus, contre des faux gh, openclaw, systemctl et
Trello (aucun appel réel). Lancer : python3 -I tests/scenario.py  (sortie 0 = tout passe)."""
import datetime as dt
import fcntl
import json
import os
import subprocess
import sys
import tempfile
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

ICI = Path(__file__).resolve().parent
OUTIL = ICI.parent / "cycle-lot"
TMP = Path(tempfile.mkdtemp(prefix="cycle-lot-test-"))
MONDE = TMP / "monde.json"
L = {"not_ready": "L-not-ready", "standby": "L-standby", "wip": "L-wip", "waiting": "L-waiting", "review": "L-review",
     "finished": "L-finished", "blocked": "L-blocked", "archived": "L-archived", "canceled": "L-canceled"}
FIL = "agent:dev:slack:channel:c000test:thread:1700000000.000100"
CL = ("# Changelog\n\nToute évolution se note sous [Unreleased] ; la PR de release la bascule.\n\n## [Unreleased]\n\n"
      "### Ajouté\n\n- carte 1\n\n## [0.9.0] - 2026-01-15\n\n### Ajouté\n\n- ancien\n")
PK = '{\n  "name": "web",\n  "version": "0.9.0",\n  "private": true\n}\n'

ECHECS = []


def monde(maj=None):
    with open(str(MONDE) + ".lock", "w") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        m = json.load(open(MONDE))
        if maj:
            maj(m)
            json.dump(m, open(MONDE, "w"), indent=1)
        fcntl.flock(f, fcntl.LOCK_UN)
    return m


class Trello(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def repondre(self, obj):
        corps = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(corps)

    def do_GET(self):
        if monde().get("trello_panne"):
            self.send_response(503)
            self.end_headers()
            return
        self.repondre(monde()["cartes"])

    def do_PUT(self):
        u = urllib.parse.urlparse(self.path)
        q = dict(urllib.parse.parse_qsl(u.query))
        cid = u.path.rsplit("/", 1)[1]

        def maj(m):
            c = next(x for x in m["cartes"] if x["id"] == cid)
            c["idList"] = q["idList"]
            c["pos"] = q.get("pos")
        monde(maj)
        self.repondre({"id": cid})

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        q = dict(urllib.parse.parse_qsl(self.rfile.read(n).decode()))
        carte = {}

        def maj(m):
            carte.update(id=f"c{len(m['cartes']) + 1}", name=q["name"], idList=q["idList"], labels=q.get("idLabels"),
                         desc=q.get("desc"), shortUrl=f"https://trello.com/c/c{len(m['cartes']) + 1}")
            m["cartes"].append(dict(carte))
        monde(maj)
        self.repondre(carte)


def lancer(*args, par=None, attendu=0):
    """Commande d'agent : lancée comme depuis l'exec d'un agent (OPENCLAW_SHELL=exec, que le faux gateway refuse
    pour un réveil, comme le vrai). La veille tourne sans, comme le service systemd du relais."""
    cmd = [sys.executable, "-I", str(OUTIL)] + (["--par", par] if par else []) + list(args)
    env = dict(ENV, OPENCLAW_SHELL="exec") if args[0] != "veille" else ENV
    r = subprocess.run(cmd, capture_output=True, text=True, env=env, cwd="/", timeout=120)
    if r.returncode != attendu:
        ECHECS.append(f"{' '.join(args)} : code {r.returncode} au lieu de {attendu}\n{r.stdout}{r.stderr}")
    return r.stdout + r.stderr


def verifier(cond, texte):
    print(("  ok   " if cond else "  ÉCHEC ") + texte)
    if not cond:
        ECHECS.append(texte)


def etat(v="1.0.0"):
    return json.loads((TMP / "cycles" / v / "etat.json").read_text())


def modifier_etat(v, maj):
    p = TMP / "cycles" / v / "etat.json"
    e = json.loads(p.read_text())
    maj(e)
    p.write_text(json.dumps(e))


def il_y_a(minutes):
    return (dt.datetime.now().astimezone() - dt.timedelta(minutes=minutes)).isoformat(timespec="seconds")


def liste_de(num, ver="1.0.0"):
    c = next(x for x in monde()["cartes"] if x["name"].startswith(f"[V{ver}-") and f"] {num}." in x["name"])
    return next(k for k, v in L.items() if v == c["idList"])


def run(d, rid, sha, event, branche, statut="completed", concl="success", jobs=None, log=""):
    return {"databaseId": rid, "status": statut, "conclusion": concl, "event": event, "headSha": sha,
            "headBranch": branche, "createdAt": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "jobs": jobs or {}, "log": log}


def pr(d, n, head, base, sha, labels=()):
    return {"number": n, "state": "OPEN", "headRefName": head, "baseRefName": base, "headRefOid": sha,
            "labels": [{"name": x} for x in labels], "mergeable": "MERGEABLE", "mergeCommit": None,
            "url": f"https://github.com/exemple/app-{d}/pull/{n}", "title": f"lot {d}"}


def derniers_reveils(n=1):
    return monde().get("reveils", [])[-n:]


# ---------------------------------------------------------------- mise en place
serveur = HTTPServer(("127.0.0.1", 0), Trello)
threading.Thread(target=serveur.serve_forever, daemon=True).start()
cartes = [{"id": f"k{i}", "name": f"[V1.0.0-{'Back' if i % 2 else 'Front'}] {i}. carte {i}", "idList": L["not_ready"]}
          for i in range(1, 5)]
cartes += [{"id": "k9", "name": "[V1.0.1-Back] 1. carte suivante", "idList": L["not_ready"]},
           {"id": "k8", "name": "[V1.0.0-Back] 7. carte annulée", "idList": L["canceled"]},
           {"id": "k7", "name": "[1.0.0][Marketing] hors format", "idList": L["not_ready"]}]
MONDE.write_text(json.dumps({
    "cartes": cartes, "prs": {"back": {}, "front": {}}, "runs": {"back": [], "front": []},
    "refs": {"back": {"release/1.0.0": "relback0".ljust(40, "0"), "feat/1.0.0-lot": "featback1".ljust(40, "0")},
             "front": {"release/1.0.0": "relfront0".ljust(40, "0"), "feat/1.0.0-lot": "featfront1".ljust(40, "0")}},
    "compare": {"back": {"develop...release/1.0.0": 3, "master...release/1.0.0": 5},
                "front": {"develop...release/1.0.0": 2, "master...release/1.0.0": 4}},
    "next_pr": 500, "next_run": 9000, "units": [], "sessions": {},
    "limite_contenu": 100,  # CHANGELOG au-delà de la limite de l'API contents (lu par l'API des blobs), package.json en deçà
    "fichiers": {"back": {"release/1.0.0": {"CHANGELOG.md": CL}},
                 "front": {"release/1.0.0": {"CHANGELOG.md": CL, "package.json": PK}}}}, indent=1))
(TMP / "openclaw.json").write_text(json.dumps({"channels": {"slack": {"accounts": {}}}}))
(TMP / "cycle-lot.json").write_text(json.dumps({
    "humain": {"nom": "Camille", "slack_id": "U0TEST"},
    "agents": {"dev": {"id": "dev", "nom": "Dev"}, "relecteur": {"id": "relecteur", "nom": "Relecteur"},
               "relais": {"id": "mainteneur", "nom": "Mainteneur"}},
    "depots": {"back": {"github": "exemple/app-back", "workflow": "back.yml", "jobs_requis_lot": ["quality", "integration"],
                        "jobs_requis_master": ["quality", "integration", "push-vert", "env-parity"]},
               "front": {"github": "exemple/app-front", "workflow": "front.yml", "jobs_requis_lot": ["quality", "e2e"],
                         "jobs_requis_master": ["quality", "e2e", "push-vert", "env-parity"]}},
    "jobs_requis_push": ["quality", "deploy"],
    "deploiement_preview": {"depot": "back", "jobs_requis": ["quality", "deploy"], "delai_min": 10},
    "urls": {"production": "https://app.example.test", "preview": "https://preview.app.example.test"},
    "trello": {"tableau": "T-test", "listes": L,
               "etiquettes_gravite": {g: f"E-{g}" for g in ("critique", "important", "normal", "faible", "cosmetique")}},
    "jobs_sautables": ["quality", "integration", "e2e"],
    "slack_archives": "https://exemple.slack.test/archives"}))
ENV = {"PATH": "/usr/bin:/bin", "MONDE": str(MONDE), "CYCLE_LOT_BASE": str(TMP), "CYCLE_LOT_GH": str(ICI / "faux/gh"),
       "OPENCLAW_BIN": str(ICI / "faux/openclaw"), "CYCLE_LOT_SYSTEMCTL": str(ICI / "faux/systemctl"),
       "CYCLE_LOT_TRELLO_API": f"http://127.0.0.1:{serveur.server_port}/1", "TRELLO_API_KEY": "k", "TRELLO_TOKEN": "t",
       "CYCLE_LOT_OPENCLAW_CONFIG": str(TMP / "openclaw.json"), "CYCLE_LOT_CONFIG": str(TMP / "cycle-lot.json"), "CYCLE_LOT_INTERVALLE_GH_MIN": "0"}
F = "0" * 32

print("1. démarrage")
out = lancer("debut", "1.0.0", "--session-key", FIL, par="relecteur", attendu=2)
verifier("seul Dev lance un lot" in out, "le relecteur ne peut pas lancer un lot")
out = lancer("debut", "1.0.0", "--session-key", "agent:relecteur:slack:channel:c000test:thread:1.2", par="dev", attendu=2)
verifier("clé de session de Dev" in out, "debut refusé avec la clé de session du relecteur")
out = lancer("debut", "1.0.0", "--session-key", FIL, "--dossier-lot", "/tmp/lot100", par="dev")
e = etat()
verifier(e["etape"] == "dev" and e["tour"] == "dev", "étape dev, main au dev")
verifier([c["num"] for c in e["cartes"]] == [1, 2, 3, 4], "cartes 1 à 4 du lot (annulée et hors format exclues)")
verifier(all(liste_de(n) == "wip" for n in range(1, 5)), "toutes les cartes en Work in progress")
lancer("debut", "1.0.0", "--session-key", FIL, par="dev", attendu=2)

out = lancer("verdict", "9.9.9", "--merger", "--rapport", "/nulle-part", par="relecteur", attendu=2)
verifier("aucun cycle pour le lot 9.9.9" in out and not (TMP / "cycles" / "9.9.9").exists(),
         "commande refusée sur un lot sans cycle : aucun dossier créé")
out = lancer("arret", "../../evasion", "--motif", "autre", "--message", "x", par="dev", attendu=2)
verifier("illisible" in out and not (TMP / "evasion").exists() and not (TMP.parent / "evasion").exists(),
         "version hors format refusée avant toute écriture")

lancer("intervention", "1.0.0", "--ajouter", "poser FOO sur backend-prod", par="dev")

print("2. passage en revue refusé tant que la CI n'est pas verte")
out = lancer("passe", "1.0.0", "--vers", "relecteur", par="relecteur", attendu=2)
verifier("la main est à dev" in out, "le relecteur ne peut pas passer la main à la place du dev")
out = lancer("passe", "1.0.0", "--vers", "relecteur", par="dev", attendu=2)
verifier("aucune PR ouverte" in out, "refus sans PR ouverte")


def prs_lot(m):
    m["prs"]["back"]["301"] = pr("back", 301, "feat/1.0.0-lot", "release/1.0.0", "featback1".ljust(40, "0"), ["ci-en-pause"])
    m["prs"]["front"]["401"] = pr("front", 401, "feat/1.0.0-lot", "release/1.0.0", "featfront1".ljust(40, "0"))
    m["runs"]["back"].append(run("back", 1, "featback1".ljust(40, "0"), "pull_request", "feat/1.0.0-lot",
                                 jobs={"quality": "success", "integration": "success"}))
    m["runs"]["front"].append(run("front", 2, "featfront1".ljust(40, "0"), "pull_request", "feat/1.0.0-lot",
                                  jobs={"quality": "success", "e2e": "skipped"}))
    for i in (1, 2, 3):
        next(c for c in m["cartes"] if c["id"] == f"k{i}")["idList"] = L["waiting"]


monde(prs_lot)
out = lancer("passe", "1.0.0", "--vers", "relecteur", par="dev", attendu=2)
verifier("ci-en-pause" in out and "e2e" in out, "refus : étiquette ci-en-pause (back) et e2e sauté (front)")


def ci_verte(m):
    m["prs"]["back"]["301"]["labels"] = []
    m["runs"]["front"].append(run("front", 3, "featfront1".ljust(40, "0"), "pull_request", "feat/1.0.0-lot",
                                  jobs={"quality": "success", "e2e": "success"}))
    m["runs"]["front"][-1]["createdAt"] = "2099-01-01T00:00:00Z"


monde(ci_verte)
lancer("veille")
av = etat()["avancement"]
verifier(av["faites"] == 3 and av["total"] == 4 and av["par_liste"] == {"Work in progress": 1, "Waiting for review": 3}
         and av["cartes"] == {"1": "waiting", "2": "waiting", "3": "waiting", "4": "wip"},
         "avancement lu par le relais : 3 cartes faites sur 4 (passes poussées, en Waiting for review)")
out = lancer("passe", "1.0.0", "--vers", "relecteur", "--message", "lot fini", par="dev", attendu=2)
verifier("--reel" in out and etat()["etape"] == "dev", "1er passage en revue refusé sans les preuves en réel (ou « aucun »)")
lancer("intervention", "1.0.0", "--ajouter", "clé du service externe en préproduction", "--avant", "revue", par="dev")
out = lancer("passe", "1.0.0", "--vers", "relecteur", "--reel", "aucun", par="dev", attendu=2)
verifier("nécessaires à la vérification" in out and "clé du service externe" in out,
         "passage en revue refusé : intervention nécessaire à la vérification encore ouverte")
lancer("intervention", "1.0.0", "--faite", "2", par="dev")
reel = TMP / "reel.md"
reel.write_text("carte 2 : traitement joué sur la préproduction, résultat attendu")
out = lancer("passe", "1.0.0", "--vers", "relecteur", "--reel", str(reel), "--message", "lot fini, arbitrages A1-A3 pris", par="dev")
e = etat()
verifier(e["etape"] == "deploiement-revue" and e["tour"] == "veille", "étape deploiement-revue, le relais attend")
verifier(e["preuves_reel"] == str(reel) and e["attente"]["deploiement"]["seul"]
         and any(x[:2] == ["workflow", "run"] and "deploiement_seul=true" in x for x in monde()["appels"]),
         "preuves en réel notées ; preview demandée en déploiement seul (sans rejouer quality)")
verifier(all(liste_de(n) == "review" for n in range(1, 5)), "cartes en Under review")
verifier("encore en Work in progress" in out and "4" in out, "carte 4 signalée encore en WIP")
disp = [r for r in monde()["runs"]["back"] if r["event"] == "workflow_dispatch"]
verifier(len(disp) == 1 and disp[0]["headBranch"] == "feat/1.0.0-lot", "back du lot déployé sur la preview (dispatch)")

print("3. veille : déploiement preview, puis réveil du relecteur")
lancer("veille")
verifier(etat()["etape"] == "deploiement-revue", "run de déploiement en cours : on attend")
monde(lambda m: m["runs"]["back"][-1].update(status="completed", conclusion="success"))
lancer("veille")
verifier(etat()["etape"] == "deploiement-revue" and etat()["attente"]["deploiement"]["vert_a"], "vert : délai de bascule de la preview")
modifier_etat("1.0.0", lambda e: e["attente"]["deploiement"].update(vert_a=il_y_a(11)))
lancer("veille")
e = etat()
r = derniers_reveils()[0]
verifier(e["etape"] == "revue" and e["tour"] == "relecteur", "étape revue, main au relecteur")
verifier(r["sessionKey"] == "agent:relecteur:slack:channel:c000test:thread:1700000000.000100"
         and r["accountId"] == "relecteur" and r["threadId"] == "1700000000.000100" and r["to"] == "channel:C000TEST"
         and r["deliver"],
         "réveil du relecteur dans sa session du fil, routage explicite")
verifier("front-preview.example.test" in r["message"] and "lot fini" in r["message"], "consigne : URL preview et message du dev")
verifier("Fais la revue complète" in r["message"] and "--disallowedTools Monitor" in r["message"],
         "1re revue : revue complète, job de revue sans suivi d'avancement")
verifier("Revue n° 1" in r["message"] and "tout se corrige" in r["message"] and "--bloquants" in r["message"]
         and str(reel) in r["message"], "1re revue : règle des revues 1 et 2, preuves en réel du dev transmises")
verifier(not monde().get("resets") and "Contexte neuf" not in r["message"],
         "contexte neuf : le relecteur n'a pas encore de session dans ce fil, rien à remettre à zéro")

print("4. verdict À REPRENDRE")
rap = TMP / "rapport1.md"
rap.write_text("points N1 N2")
out = lancer("verdict", "1.0.0", "--a-reprendre", "--rapport", str(rap), "--cartes-ok", "1,2", "--cartes-ko", "3,4",
             par="relecteur", attendu=2)
verifier("--bloquants N" in out, "refus : À REPRENDRE sans le nombre de points bloquants")
out = lancer("verdict", "1.0.0", "--merger", "--non-bloquants", "2", "--rapport", str(rap), par="relecteur", attendu=2)
verifier("aux revues 1 et 2, un point non bloquant se corrige" in out, "revue 1 : À MERGER refusé avec des non bloquants")
out = lancer("verdict", "1.0.0", "--a-reprendre", "--bloquants", "0", "--rapport", str(rap), "--cartes-ok", "1,2", par="relecteur",
             attendu=2)
verifier("manquent : [3, 4]" in out, "refus : cartes non classées")
out = lancer("verdict", "1.0.0", "--a-reprendre", "--bloquants", "0", "--non-bloquants", "2", "--rapport", str(rap),
             "--cartes-ok", "1,2", "--cartes-ko", "3,4", par="relecteur")
verifier(etat()["a_reveiller"]["agent"] == "dev" and len(monde().get("reveils", [])) == 1, "réveil du dev planifié, pas fait par la commande")
monde(lambda m: m["sessions"].update(dev=[{"key": FIL, "sessionId": "s-dev-1", "hasActiveRun": True}]))
lancer("veille")
verifier(len(monde().get("reveils", [])) == 1 and etat()["a_reveiller"] and not monde().get("resets"),
         "contexte neuf : un tour du dev tourne, ni remise à zéro ni réveil (le relais repasse)")
monde(lambda m: m["sessions"]["dev"][0].update(hasActiveRun=False))
lancer("veille")
rs = monde().get("resets", [])
verifier(len(rs) == 1 and rs[0]["key"] == FIL and rs[0].get("expectedSessionId") == "s-dev-1" and rs[0]["reason"] == "reset",
         "contexte neuf : session du dev remise à zéro avant l'étape correction, sur le sessionId lu")
verifier("Contexte neuf" in derniers_reveils()[0]["message"], "consigne : contexte neuf signalé au dev")
verifier("Corrige TOUS les points" in derniers_reveils()[0]["message"] and "la famille, pas le cas" in derniers_reveils()[0]["message"]
         and "--contre-relecture" in derniers_reveils()[0]["message"],
         "revue 1 À REPRENDRE sans bloquant : tout se corrige, par famille, avec contre-relecture")
e = etat()
verifier(e["etape"] == "correction" and e["aller_retours"] == 1, "étape correction, aller-retour 1")
verifier(e["rapports"][-1]["tetes"] == {"back#301": "featback1".ljust(40, "0"), "front#401": "featfront1".ljust(40, "0")},
         "têtes revues notées avec le rapport")
verifier([liste_de(n) for n in range(1, 5)] == ["finished", "finished", "wip", "wip"], "cartes 1-2 Finished, 3-4 WIP")
av = etat()["avancement"]
verifier(av["faites"] == 2 and av["total"] == 4 and av["par_liste"] == {"Work in progress": 2, "Finished": 2},
         "avancement : 2/4 après le verdict, les cartes renvoyées en Work in progress repassent dans le reste à faire")
monde(lambda m: m.update(trello_panne=True))
lancer("veille")
lancer("veille")
av = etat()["avancement"]
jl = (TMP / "cycles" / "1.0.0" / "journal.log").read_text()
pouls = json.loads((TMP / "cycles" / ".veille.json").read_text())
verifier(av["faites"] == 2 and av["total"] == 4 and av.get("erreur") and pouls["erreurs"] == []
         and jl.count("avancement : lecture de Trello impossible") == 1,
         "Trello en panne : dernier compte gardé, erreur notée une seule fois, pas une erreur du relais")


def annuler_4(m):
    m["trello_panne"] = False
    next(c for c in m["cartes"] if c["id"] == "k4")["idList"] = L["canceled"]


monde(annuler_4)
lancer("veille")
av = etat()["avancement"]
verifier(av["faites"] == 2 and av["total"] == 3 and "erreur" not in av and av["cartes"]["4"] == "canceled",
         "Trello revenu : compte à jour, une carte annulée sort du total")
monde(lambda m: next(c for c in m["cartes"] if c["id"] == "k4").update(idList=L["wip"]))
verifier(derniers_reveils()[0]["sessionKey"] == FIL and "rapport1.md" in derniers_reveils()[0]["message"], "dev réveillé avec le rapport")
lancer("ouvrir-livraison", "1.0.0", par="dev", attendu=2)


def correction(m):
    for d, n, sha in (("back", "301", "featback2"), ("front", "401", "featfront2")):
        m["prs"][d][n]["headRefOid"] = sha.ljust(40, "0")
        m["runs"][d].append(run(d, 10 + int(n), sha.ljust(40, "0"), "pull_request", "feat/1.0.0-lot",
                                jobs={"quality": "success", "integration": "success", "e2e": "success"}))
    for i in (3, 4):
        next(c for c in m["cartes"] if c["id"] == f"k{i}")["idList"] = L["waiting"]


monde(correction)
out = lancer("passe", "1.0.0", "--vers", "relecteur", "--message", "N1 N2 corrigés", par="dev", attendu=2)
verifier("--contre-relecture" in out and etat()["etape"] == "correction", "correction : passage refusé sans contre-relecture")
cr = TMP / "contre-relecture.md"
cr.write_text("diff relu : rien de cassé")
lancer("passe", "1.0.0", "--vers", "relecteur", "--contre-relecture", str(cr), "--message", "N1 N2 corrigés", par="dev")
monde(lambda m: m["runs"]["back"][-1].update(status="completed", conclusion="success"))
lancer("veille")
modifier_etat("1.0.0", lambda e: e["attente"]["deploiement"].update(vert_a=il_y_a(11)))
lancer("veille")
e = etat()
verifier(e["etape"] == "revue" and "rapport1.md" in derniers_reveils()[0]["message"], "2e revue : rappel du rapport précédent")
msg = derniers_reveils()[0]["message"]
verifier("Revue de CORRECTION" in msg and "git diff featback1000..featback2000" in msg
         and "Fais la revue complète" not in msg, "2e revue ciblée : diff exact depuis la tête revue, pas de revue complète")
verifier([liste_de(n) for n in range(1, 5)] == ["finished", "finished", "review", "review"], "seules 3-4 repassent en revue")

print("5. verdict À MERGER : merges gardés dans la même commande, puis commit de release")
rap2 = TMP / "rapport2.md"
rap2.write_text("tout est bon")
monde(lambda m: m["prs"]["back"]["301"].update(headRefOid="pousse-apres-revue".ljust(40, "0")))
out = lancer("verdict", "1.0.0", "--merger", "--rapport", str(rap2), par="relecteur")
verifier(etat()["etape"] == "merge-lot" and all(liste_de(n) == "finished" for n in range(1, 5)), "merge-lot, cartes Finished")
verifier("a bougé depuis la revue" in out and monde()["prs"]["back"]["301"]["state"] == "OPEN",
         "merge refusé dans le verdict : tête modifiée depuis la revue, la main reste au relecteur")
out = lancer("merge", "1.0.0", "--pr", "front#401", par="relecteur", attendu=2)
verifier("back d'abord" in out, "refus : front avant back")
monde(lambda m: m["prs"]["back"]["301"].update(headRefOid="featback2".ljust(40, "0")))
lancer("merge", "1.0.0", "--pr", "back#301", par="relecteur")
lancer("merge", "1.0.0", "--pr", "front#401", par="relecteur")
m = monde()
verifier(m["prs"]["back"]["301"]["methode"] == "squash" and m["prs"]["front"]["401"]["state"] == "MERGED", "PR du lot squashées")
verifier(etat()["etape"] == "ci-release", "étape ci-release : le relais attend la CI du push sur la release")
e = etat()
verifier(set(e.get("bascule", {})) == {"back", "front"} and m["refs"]["back"]["release/1.0.0"] == e["bascule"]["back"][-1],
         "commit de release poussé sur release/1.0.0, back et front")
cl = m["fichiers"]["back"]["release/1.0.0"]["CHANGELOG.md"]
verifier("## [Unreleased]\n\n## [1.0.0] - " in cl and cl.index("## [1.0.0]") < cl.index("- carte 1") < cl.index("## [0.9.0]"),
         "CHANGELOG : la section [1.0.0] ouvre ce qui était sous [Unreleased]")
verifier('"version": "1.0.0"' in m["fichiers"]["front"]["release/1.0.0"]["package.json"]
         and "package.json" not in m["fichiers"]["back"]["release/1.0.0"], "package.json du front passé en 1.0.0")
verifier(m.get("lectures_blob", 0) >= 2, "CHANGELOG de plus de 1 Mo (limite de l'API contents) lu par l'API des blobs")
verifier(e["commits_revus"] == {"back": ["mergeback301".ljust(40, "0")], "front": ["mergefront401".ljust(40, "0")]},
         "commits de merge du lot notés comme revus")

print("6. CI de la release, rouge réseau relancé une fois")


def push_release(m):
    m["runs"]["back"].append(run("back", 50, m["refs"]["back"]["release/1.0.0"], "push", "release/1.0.0",
                                 jobs={"quality": "success", "deploy": "success"}))
    m["runs"]["front"].append(run("front", 51, m["refs"]["front"]["release/1.0.0"], "push", "release/1.0.0", concl="failure",
                                  jobs={"quality": "failure", "deploy": "skipped"}, log="npm ERR! ECONNRESET"))


monde(push_release)
lancer("veille")
verifier(etat()["etape"] == "ci-release" and monde()["runs"]["front"][-1].get("relance") == 1, "rouge réseau : relancé une fois")
suivi = {s["depot"]: s for s in etat()["attente"].get("suivi", [])}
verifier(suivi.get("back", {}).get("verdict") == "vert" and suivi.get("front", {}).get("verdict") == "en cours"
         and suivi["front"]["url"].endswith("/actions/runs/51") and "relancé" in suivi["front"]["resume"],
         "runs attendus suivis dans l'état pour le monitor (vert, relancé, lien)")
pouls = json.loads((TMP / "cycles" / ".veille.json").read_text())
verifier(pouls["lots"] == ["1.0.0"] and not pouls["erreurs"] and pouls["derniere"], "pouls du relais écrit pour le monitor")
monde(lambda m: m["runs"]["front"][-1].update(status="completed", conclusion="success", jobs={"quality": "success", "deploy": "success"}))
lancer("veille")
verifier(etat()["etape"] == "livraison" and derniers_reveils()[0]["sessionKey"] == FIL, "livraison, dev réveillé")

print("7. PR de livraison (intervention ouverte : c'est le dev qui livre)")
out = lancer("ouvrir-livraison", "1.0.0", par="dev", attendu=2)
verifier("interventions de Camille encore ouvertes" in out, "refus : intervention de l'humain pas faite")
lancer("intervention", "1.0.0", "--faite", "1", par="dev")
lancer("ouvrir-livraison", "1.0.0", par="dev")
e = etat()
verifier(len(e["prs_livraison"]) == 4 and e["etape"] == "ci-livraison", "4 PR de livraison, le relais attend leur CI")
lancer("veille")
verifier(etat()["etape"] == "ci-livraison", "CI des PR vers master pas encore lancée : on attend")


def ci_master(m):
    m["compare_commits"] = {"back": {"develop...release/1.0.0": [m["refs"]["back"]["release/1.0.0"], "intrus".ljust(40, "0")]}}
    for d in ("back", "front"):
        m["runs"][d].append(run(d, 60, m["refs"][d]["release/1.0.0"], "pull_request", "release/1.0.0",
                                jobs={"quality": "success", "integration": "success", "e2e": "success",
                                      "push-vert": "success", "env-parity": "success"}))


monde(ci_master)
lancer("veille")
verifier(etat()["etape"] == "revue-livraison" and derniers_reveils()[0]["accountId"] == "relecteur"
         and "hors du lot revu" in derniers_reveils()[0]["message"],
         "commit étranger au lot dans la release : pas de merge automatique, relecteur réveillé pour la revue de livraison")
lpr = {(p["depot"], p["base"]): p["num"] for p in etat()["prs_livraison"]}
lancer("merge", "1.0.0", "--pr", f"front#{lpr[('front', 'develop')]}", par="relecteur", attendu=2)
for cle in (("back", "develop"), ("back", "master"), ("front", "develop"), ("front", "master")):
    lancer("merge", "1.0.0", "--pr", f"{cle[0]}#{lpr[cle]}", par="relecteur")
verifier(monde()["prs"]["back"][str(lpr[("back", "master")])]["methode"] == "merge", "livraison en commit de merge")
verifier(etat()["etape"] == "deploiement", "étape deploiement : le relais attend la CI de develop et master")

print("8. mise en production, liste des validations, validations")


def ci_prod(m):
    for d in ("back", "front"):
        for base in ("develop", "master"):
            n = str(lpr[(d, base)])
            m["runs"][d].append(run(d, 70, m["prs"][d][n]["mergeCommit"]["oid"], "push", base,
                                    jobs={"quality": "success", "deploy": "success"}))


monde(ci_prod)
lancer("veille")
verifier(etat()["etape"] == "liste-validation" and derniers_reveils()[0]["sessionKey"] == FIL, "lot en prod, dev réveillé")
liste = TMP / "liste.md"
lancer("passe", "1.0.0", "--vers", "relecteur", "--etape", "validation-prod", "--fichier", str(liste), par="dev", attendu=2)
liste.write_text("1. carte 1 : …")
lancer("passe", "1.0.0", "--vers", "relecteur", "--etape", "validation-prod", "--fichier", str(liste), par="dev")
lancer("veille")
verifier(etat()["etape"] == "validation-prod" and str(liste) in derniers_reveils()[0]["message"], "relecteur réveillé avec la liste")
desc = TMP / "bug.md"
desc.write_text("constat, parcours, attendu")
out = lancer("carte-bug", "1.0.0", "--titre", "Le badge déborde", "--appli", "front", "--gravite", "normal",
             "--description-fichier", str(desc), par="relecteur")
c = monde()["cartes"][-1]
verifier(c["name"] == "[V1.0.1-Fix-Front] 2. Le badge déborde" and c["idList"] == L["not_ready"]
         and c["labels"] == "E-normal", "carte de bug : version suivante, numéro suivant, Not Ready, gravité")
lancer("fin", "1.0.0", "--rapport", str(desc), par="relecteur")
verifier(etat()["etape"] == "livre", "lot livré")

print("9. relances d'un agent muet, puis alerte à l'humain")
lancer("debut", "1.0.1", "--session-key", FIL.replace("000100", "000200"), par="dev")
lancer("veille")
n0 = len(monde().get("reveils", []))
r0 = len(monde().get("resets", []))
modifier_etat("1.0.1", lambda e: e.update(depuis=il_y_a(50)))
monde(lambda m: m.update(units=["dev-101-impl.service"]))
lancer("veille")
verifier(len(monde().get("reveils", [])) == n0, "job dev-101-* actif : pas de relance")
monde(lambda m: m.update(units=["dev-1011-impl.service", "relecteur-101-rev1.service"]))
modifier_etat("1.0.1", lambda e: e["relances"].update(vu_actif=il_y_a(50), verif_session=None))
lancer("veille")
verifier("Relance automatique n°1" in derniers_reveils()[0]["message"], "pas de job dev-101-* : relance n°1")
modifier_etat("1.0.1", lambda e: e["relances"].update(derniere=il_y_a(50), verif_session=il_y_a(11)))
lancer("veille")
verifier("Relance automatique n°2" in derniers_reveils()[0]["message"], "relance n°2")
modifier_etat("1.0.1", lambda e: e["relances"].update(derniere=il_y_a(50), verif_session=il_y_a(11)))
lancer("veille")
verifier("ne répond pas" in monde()["avis"][-1] and "<@U0TEST>" in monde()["avis"][-1], "alerte postée à l'humain")
verifier("ne répond pas" in monde()["dm"][-1] and "/archives/C000TEST/p1700000000000200" in monde()["dm"][-1],
         "alerte envoyée aussi en message direct à l'humain, avec le lien du fil")
na, nd = len(monde()["avis"]), len(monde()["dm"])
modifier_etat("1.0.1", lambda e: e["relances"].update(verif_session=il_y_a(11), alerte_heure=il_y_a(60)))
lancer("veille")
verifier(len(monde()["avis"]) == na, "pas de rappel avant 2 h")
modifier_etat("1.0.1", lambda e: e["relances"].update(verif_session=il_y_a(11), alerte_heure=il_y_a(121)))
lancer("veille")
verifier(len(monde()["avis"]) == na + 1 and "rappel n° 1" in monde()["avis"][-1] and len(monde()["dm"]) == nd + 1,
         "alerte répétée au bout de 2 h, dans le fil et en message direct")
monde(lambda m: m.update(units=["dev-101-impl.service"]))
lancer("veille")
rl = etat("1.0.1")["relances"]
verifier(rl["nb"] == 0 and not rl["alerte"], "signe de vie (job relancé) : relances et alerte réarmées")
verifier(len(monde().get("resets", [])) == r0, "contexte neuf : aucune remise à zéro pour une relance")
monde(lambda m: m.update(units=[]))

print("10. arrêt au 5e aller-retour, reprise")
verifier(etat("1.0.1")["max_aller_retours"] == 5, "plafond de 5 aller-retours à la création du cycle")
modifier_etat("1.0.1", lambda e: e.update(etape="revue", tour="relecteur", aller_retours=4))
monde(lambda m: [c.update(idList=L["review"]) for c in m["cartes"] if c["name"].startswith("[V1.0.1-")])
out = lancer("verdict", "1.0.1", "--a-reprendre", "--bloquants", "1", "--non-bloquants", "0", "--rapport", str(rap),
             "--cartes-ko", "1,2", par="relecteur")
e = etat("1.0.1")
verifier(e["etape"] == "arret" and e["arret"]["motif"] == "aller-retours", "5e À REPRENDRE : cycle arrêté")
lancer("veille")
verifier("cycle arrêté (aller-retours)" in monde()["avis"][-1] and "en mentionnant Relecteur" in monde()["avis"][-1],
         "avis d'arrêt posté pour l'humain par le relais, avec l'agent à mentionner")
verifier("cycle arrêté (aller-retours)" in monde()["dm"][-1], "arrêt envoyé aussi en message direct à l'humain")
out = lancer("reprise", "1.0.1", "--decision", "continue", par="dev", attendu=2)
verifier("--rallonge" in out, "reprise refusée sans rallonge")
lancer("reprise", "1.0.1", "--decision", "une correction de plus", "--rallonge", par="dev")
verifier(etat("1.0.1")["etape"] == "correction" and etat("1.0.1")["max_aller_retours"] == 6, "reprise en correction, plafond 6")

print("11. gateway en panne : nouveaux essais puis avis")
monde(lambda m: m.update(gateway_en_panne=True))
modifier_etat("1.0.1", lambda e: e.update(etape="liste-validation", tour="dev", seq=e["seq"] + 1))
lancer("reveiller", "1.0.1", par="dev")
lancer("veille")
verifier(etat("1.0.1")["a_reveiller"]["essais"] == 1, "réveil en échec noté")
for _ in range(3):
    lancer("veille")
verifier(etat("1.0.1")["a_reveiller"]["essais"] == 4, "trois nouveaux essais")
lancer("veille")
verifier("impossible de réveiller Dev" in monde()["avis"][-1], "avis : impossible de réveiller")
monde(lambda m: m.update(gateway_en_panne=False))

print("12. lancement différé demandé par l'humain")
lancer("programmer", "1.0.2", "--apres", "1.0.0", "--session-key", FIL.replace("000100", "000300"), par="dev")
lancer("veille")
r = derniers_reveils()[0]
verifier("attaquer ensuite le lot 1.0.2" in r["message"] and r["threadId"] == "1700000000.000300", "dev réveillé pour 1.0.2")
lancer("veille")
verifier(sum("1.0.2" in x["message"] for x in monde()["reveils"]) == 1, "un seul réveil")

print("14. piste 2 : merges au verdict, commit de release, PR de livraison ouvertes et mergées par le relais")
F3 = FIL.replace("000100", "000400")


def lot103(m):
    m["cartes"].append({"id": "k31", "name": "[V1.0.3-Back] 1. carte trois", "idList": L["not_ready"]})
    for d, n, sha in (("back", "801", "featback3"), ("front", "901", "featfront3")):
        m["prs"][d][n] = pr(d, int(n), "feat/1.0.3-lot", "release/1.0.3", sha.ljust(40, "0"))
        m["runs"][d].append(run(d, 1000 + int(n), sha.ljust(40, "0"), "pull_request", "feat/1.0.3-lot",
                                jobs={"quality": "success", "integration": "success", "e2e": "success"}))
        m["refs"][d]["release/1.0.3"] = f"rel{d}3".ljust(40, "0")
        m["fichiers"][d]["release/1.0.3"] = {"CHANGELOG.md": CL}
        m["compare"][d].update({"develop...release/1.0.3": 2, "master...release/1.0.3": 3})
    m["fichiers"]["front"]["release/1.0.3"]["package.json"] = PK


monde(lot103)
lancer("debut", "1.0.3", "--session-key", F3, par="dev")
modifier_etat("1.0.3", lambda e: e.update(etape="revue", tour="relecteur", prs_lot=[
    {"depot": d, "num": int(n), "branche": "feat/1.0.3-lot", "sha": sha.ljust(40, "0"), "labels": [],
     "url": f"https://github.com/exemple/app-{d}/pull/{n}"} for d, n, sha in (("back", "801", "featback3"),
                                                                                  ("front", "901", "featfront3"))]))
monde(lambda m: next(c for c in m["cartes"] if c["id"] == "k31").update(idList=L["review"]))
nr = len(monde().get("reveils", []))
out = lancer("verdict", "1.0.3", "--merger", "--rapport", str(rap2), par="relecteur")
m, e = monde(), etat("1.0.3")
verifier(m["prs"]["back"]["801"]["methode"] == "squash" and m["prs"]["front"]["901"]["methode"] == "squash"
         and e["etape"] == "ci-release", "verdict À MERGER : les deux PR du lot mergées dans la commande, CI de la release")
verifier("## [1.0.3] - " in m["fichiers"]["front"]["release/1.0.3"]["CHANGELOG.md"]
         and '"version": "1.0.3"' in m["fichiers"]["front"]["release/1.0.3"]["package.json"], "commit de release du lot 1.0.3")
monde(lambda m: [m["runs"][d].append(run(d, 1100, m["refs"][d]["release/1.0.3"], "push", "release/1.0.3",
                                         jobs={"quality": "success", "deploy": "success"})) for d in ("back", "front")])
lancer("veille")
e = etat("1.0.3")
verifier(e["etape"] == "ci-livraison" and len(e["prs_livraison"]) == 4 and len(monde().get("reveils", [])) == nr
         and "PR de livraison ouvertes" in monde()["avis"][-1],
         "aucune intervention : le relais ouvre les 4 PR de livraison lui-même, sans réveiller le dev")
monde(lambda m: [m["runs"][d].append(run(d, 1200, m["refs"][d]["release/1.0.3"], "pull_request", "release/1.0.3",
                                         jobs={"quality": "success", "integration": "success", "e2e": "success",
                                               "push-vert": "success", "env-parity": "success"})) for d in ("back", "front")])
monde(lambda m: m["compare_commits"].update(
    back={"develop...release/1.0.3": [m["prs"]["back"]["801"]["mergeCommit"]["oid"]] + etat("1.0.3")["bascule"]["back"]},
    front={"develop...release/1.0.3": [m["prs"]["front"]["901"]["mergeCommit"]["oid"]] + etat("1.0.3")["bascule"]["front"]}))
lancer("veille")
e, m = etat("1.0.3"), monde()
verifier(e["etape"] == "deploiement" and all(m["prs"][p["depot"]][str(p["num"])]["methode"] == "merge" for p in e["prs_livraison"])
         and len(m.get("reveils", [])) == nr and "PR de livraison mergées" in m["avis"][-1],
         "CI verte et contenu = lot revu : le relais merge les 4 PR de livraison, sans réveiller le relecteur")

print("15. carte reportée en cours de lot : elle sort du lot, le verdict À MERGER ne la passe pas en Finished")
F5 = FIL.replace("000100", "000500")
J4 = TMP / "cycles" / "1.0.4" / "journal.log"


def lot104(m):
    for i in range(1, 5):
        m["cartes"].append({"id": f"k4{i}", "name": f"[V1.0.4-Back] {i}. carte {i}", "idList": L["not_ready"]})
    for d, n, sha in (("back", "811", "featback4"), ("front", "911", "featfront4")):
        m["prs"][d][n] = pr(d, int(n), "feat/1.0.4-lot", "release/1.0.4", sha.ljust(40, "0"))
        m["runs"][d].append(run(d, 1300 + int(n), sha.ljust(40, "0"), "pull_request", "feat/1.0.4-lot",
                                jobs={"quality": "success", "integration": "success", "e2e": "success"}))
        m["refs"][d]["release/1.0.4"] = f"rel{d}4".ljust(40, "0")
        m["refs"][d]["feat/1.0.4-lot"] = sha.ljust(40, "0")
        m["fichiers"][d]["release/1.0.4"] = {"CHANGELOG.md": CL}
        m["compare"][d].update({"develop...release/1.0.4": 2, "master...release/1.0.4": 3})
    m["fichiers"]["front"]["release/1.0.4"]["package.json"] = PK


def carte(cid):
    return next(c for c in monde()["cartes"] if c["id"] == cid)


def renommer(cid, nom):
    monde(lambda m: next(c for c in m["cartes"] if c["id"] == cid).update(name=nom))


def reporter_3(m):
    # la carte 3 est reportée en 1.0.5 (renommée et remise en Not Ready) ; la carte 4 est remise en Not Ready sans
    # être renommée ; les passes des cartes 1 et 2 sont poussées
    k = {c["id"]: c for c in m["cartes"]}
    k["k43"].update(name="[V1.0.5-Back] 1. carte 3", idList=L["not_ready"])
    k["k44"]["idList"] = L["not_ready"]
    for i in (1, 2):
        k[f"k4{i}"]["idList"] = L["waiting"]


monde(lot104)
lancer("debut", "1.0.4", "--session-key", F5, par="dev")
verifier([c["num"] for c in etat("1.0.4")["cartes"]] == [1, 2, 3, 4], "lot 1.0.4 : cartes 1 à 4")
monde(reporter_3)
lancer("veille")
e = etat("1.0.4")
verifier([c["num"] for c in e["cartes"]] == [1, 2, 4] and e["cartes_sorties"][0]["version"] == "1.0.5"
         and "carte 3 sortie du lot : renommée [V1.0.5-Back] 1, en Not Ready" in J4.read_text(),
         "relais : la carte renommée [V1.0.5-…] sort du lot, avec une ligne de journal")
av = e["avancement"]
verifier(av["faites"] == 2 and av["total"] == 3 and "3" not in av["cartes"], "avancement : 2/3, la carte reportée hors du total")
out = lancer("etat", "1.0.4")
verifier("Cartes : 1, 2, 4" in out and "Sorties du lot : 3 -> [V1.0.5-Back] 1" in out, "etat : la carte reportée est listée à part")
lancer("veille")
verifier(J4.read_text().count("sortie du lot") == 1, "sortie notée une seule fois")
lancer("passe", "1.0.4", "--vers", "relecteur", "--reel", "aucun", par="dev")
verifier([liste_de(n, "1.0.4") for n in (1, 2, 4)] == ["review", "review", "not_ready"]
         and carte("k43")["idList"] == L["not_ready"], "passage en revue : les cartes en Not Ready ne bougent pas")
modifier_etat("1.0.4", lambda e: e.update(etape="revue", tour="relecteur"))
out = lancer("verdict", "1.0.4", "--a-reprendre", "--bloquants", "1", "--rapport", str(rap), "--cartes-ok", "1,2",
             "--cartes-ko", "3", par="relecteur", attendu=2)
verifier("cartes inconnues du lot : [3]" in out, "verdict : une carte reportée ne peut plus être classée")
renommer("k43", "[V1.0.4-Back] 3. carte 3")
lancer("veille")
verifier([c["num"] for c in etat("1.0.4")["cartes"]] == [1, 2, 3, 4] and "carte 3 revenue dans le lot" in J4.read_text(),
         "carte rendue à la version du lot : elle y revient")
renommer("k43", "[V1.0.5-Back] 1. carte 3")
out = lancer("verdict", "1.0.4", "--merger", "--rapport", str(rap2), par="relecteur")
e = etat("1.0.4")
verifier(carte("k41")["idList"] == L["finished"] and carte("k42")["idList"] == L["finished"]
         and carte("k43")["idList"] == L["not_ready"] and carte("k44")["idList"] == L["not_ready"],
         "À MERGER : cartes revues en Finished ; la carte reportée et celle restée en Not Ready ne bougent pas")
verifier([c["num"] for c in e["cartes"]] == [1, 2, 4] and "laissées en place, hors revue : 4 (Not Ready)" in out
         and e["etape"] == "ci-release",
         "verdict : report détecté dans la commande même (sans passage du relais), carte 4 signalée, PR mergées")
renommer("k41", "[V1.0.5-Back] 2. carte 1")
lancer("veille")
verifier([c["num"] for c in etat("1.0.4")["cartes"]] == [1, 2, 4], "après le verdict À MERGER, la liste du lot ne suit plus le tableau")
verifier("sortie du lot" not in (TMP / "cycles" / "1.0.0" / "journal.log").read_text(),
         "lot 1.0.0 du banc : aucune sortie de carte sans renommage (carte annulée comprise)")


print("16. règle de revue : à partir de la 3e revue, non bloquants en cartes du lot suivant")
F6 = FIL.replace("000100", "000600")


def nouveau_lot(v, nb, npr, cartes=2):
    def maj(m):
        for i in range(1, cartes + 1):
            m["cartes"].append({"id": f"k{v}-{i}", "name": f"[V{v}-Back] {i}. carte {i}", "idList": L["not_ready"]})
        for d, n in (("back", nb), ("front", npr)):
            sha = f"feat{d}{v}".ljust(40, "0")
            m["prs"][d][str(n)] = pr(d, n, f"feat/{v}-lot", f"release/{v}", sha)
            m["runs"][d].append(run(d, 2000 + n, sha, "pull_request", f"feat/{v}-lot",
                                    jobs={"quality": "success", "integration": "success", "e2e": "success"}))
            m["refs"][d][f"release/{v}"] = f"rel{d}{v}".ljust(40, "0")
            m["refs"][d][f"feat/{v}-lot"] = sha
            m["fichiers"][d][f"release/{v}"] = {"CHANGELOG.md": CL}
            m["compare"][d].update({f"develop...release/{v}": 2, f"master...release/{v}": 3})
        m["fichiers"]["front"][f"release/{v}"]["package.json"] = PK
    monde(maj)


def en_revue(v, nb, npr, aller_retours):
    monde(lambda m: [c.update(idList=L["review"]) for c in m["cartes"] if c["name"].startswith(f"[V{v}-")])
    modifier_etat(v, lambda e: e.update(etape="revue", tour="relecteur", aller_retours=aller_retours, attente=None, prs_lot=[
        {"depot": d, "num": n, "branche": f"feat/{v}-lot", "sha": f"feat{d}{v}".ljust(40, "0"), "labels": [],
         "url": f"https://github.com/exemple/app-{d}/pull/{n}"} for d, n in (("back", nb), ("front", npr))]))


nouveau_lot("2.0.6", 821, 921)
lancer("debut", "2.0.6", "--session-key", F6, par="dev")
en_revue("2.0.6", 821, 921, 2)
modifier_etat("2.0.6", lambda e: e.update(seq=e["seq"] + 1))
lancer("reveiller", "2.0.6", "--agent", "relecteur", par="relecteur")
out = lancer("verdict", "2.0.6", "--a-reprendre", "--bloquants", "0", "--non-bloquants", "2", "--rapport", str(rap),
             "--cartes-ko", "1,2", par="relecteur", attendu=2)
verifier("un lot sans point bloquant se merge" in out, "3e revue : À REPRENDRE refusé sans point bloquant")
out = lancer("verdict", "2.0.6", "--a-reprendre", "--bloquants", "1", "--rapport", str(rap), "--cartes-ko", "1,2",
             par="relecteur", attendu=2)
verifier("--non-bloquants N" in out, "3e revue : nombre de points non bloquants exigé")
out = lancer("verdict", "2.0.6", "--a-reprendre", "--bloquants", "1", "--non-bloquants", "2", "--rapport", str(rap),
             "--cartes-ko", "1,2", par="relecteur", attendu=2)
verifier("2 point(s) non bloquant(s) annoncé(s), 0 carte(s)" in out, "3e revue : chaque non bloquant doit avoir sa carte")
lancer("carte-report", "2.0.6", "--titre", "Libellé tronqué", "--appli", "front", "--gravite", "faible",
       "--description-fichier", str(desc), par="relecteur")
out = lancer("carte-report", "2.0.6", "--titre", "Journal incomplet", "--appli", "back", "--gravite", "normal",
             "--description-fichier", str(desc), "--version-cible", "2.0.9", par="relecteur")
noms = [c["name"] for c in monde()["cartes"][-2:]]
verifier(noms == ["[V2.0.7-Fix-Front] 1. Libellé tronqué", "[V2.0.9-Fix-Back] 1. Journal incomplet"]
         and all(c["idList"] == L["not_ready"] for c in monde()["cartes"][-2:]),
         "carte-report : cartes du lot suivant (ou de la version demandée), en Not Ready")
out = lancer("carte-report", "2.0.6", "--titre", "x", "--appli", "back", "--gravite", "normal", "--description-fichier",
             str(desc), "--version-cible", "2.0.5", par="relecteur", attendu=2)
verifier("postérieure au lot" in out, "carte-report : version antérieure au lot refusée")
lancer("verdict", "2.0.6", "--a-reprendre", "--bloquants", "1", "--non-bloquants", "2", "--rapport", str(rap),
       "--cartes-ok", "1", "--cartes-ko", "2", par="relecteur")
lancer("veille")
e, msg = etat("2.0.6"), derniers_reveils()[0]["message"]
verifier(e["etape"] == "correction" and e["aller_retours"] == 3 and "points BLOQUANTS" in msg and "eux seuls" in msg
         and "[V2.0.7-Fix-Front] 1. Libellé tronqué" in msg and "Corrige TOUS" not in msg,
         "3e revue À REPRENDRE : le dev ne corrige que les bloquants, les cartes reportées lui sont nommées")
en_revue("2.0.6", 821, 921, 3)
lancer("veille")
lancer("reveiller", "2.0.6", "--agent", "relecteur", par="relecteur")
lancer("veille")
msg = derniers_reveils()[0]["message"]
verifier("Revue n° 4" in msg and "seul un point BLOQUANT" in msg and "carte-report" in msg,
         "consigne de la 4e revue : seul un bloquant renvoie le lot, non bloquants en cartes")
lancer("carte-report", "2.0.6", "--titre", "Reste mineur", "--appli", "back", "--gravite", "faible",
       "--description-fichier", str(desc), par="relecteur")
out = lancer("verdict", "2.0.6", "--merger", "--non-bloquants", "2", "--rapport", str(rap2), par="relecteur", attendu=2)
verifier("1 carte(s) créée(s)" in out, "4e revue : À MERGER refusé tant qu'un non bloquant n'a pas sa carte")
out = lancer("verdict", "2.0.6", "--merger", "--non-bloquants", "1", "--rapport", str(rap2), par="relecteur")
e = etat("2.0.6")
verifier(e["etape"] == "ci-release" and len(e["cartes_reportees"]) == 3 and "Cartes reportées" in lancer("etat", "2.0.6"),
         "4e revue sans bloquant : lot mergé, non bloquants en cartes du lot suivant")

print("17. voie courte : correctif d'après merge sur la CI ou les tests, sans preview et hors compteur")


def pr_correctif(n, fichiers, sha):
    def maj(m):
        p = pr("front", n, "fix/2.0.6-ci-release", "release/2.0.6", sha.ljust(40, "0"))
        p["files"] = [{"path": f} for f in fichiers]
        m["prs"]["front"][str(n)] = p
        m["runs"]["front"].append(run("front", 3000 + n, sha.ljust(40, "0"), "pull_request", "fix/2.0.6-ci-release",
                                      jobs={"quality": "success", "e2e": "success"}))
    monde(maj)


monde(lambda m: [m["runs"][d].append(run(d, 2100, m["refs"][d]["release/2.0.6"], "push", "release/2.0.6",
                                         concl="success" if d == "back" else "failure",
                                         jobs={"quality": "success" if d == "back" else "failure",
                                               "deploy": "success" if d == "back" else "skipped"})) for d in ("back", "front")])
monde(lambda m: m["runs"]["back"][-1].update(status="in_progress", conclusion=None))
lancer("veille")
e = etat("2.0.6")
verifier(e["etape"] == "correction" and e["release_a_verifier"] == ["back", "front"],
         "rouge immédiat : front rouge sur la release, back encore en cours, dev réveillé sans attendre le plafond")
pr_correctif(931, [".github/workflows/front.yml", "tests/unit/workflowE2e.test.ts", "docs/release.md"], "fix1")
nd = sum(1 for x in monde()["appels"] if x[:2] == ["workflow", "run"])
out = lancer("passe", "2.0.6", "--vers", "relecteur", "--message", "délai e2e relevé", par="dev")
lancer("veille")
e, msg = etat("2.0.6"), derniers_reveils()[0]["message"]
verifier(e["etape"] == "revue" and e["attente"].get("voie_courte") and "voie courte" in out.lower()
         and sum(1 for x in monde()["appels"] if x[:2] == ["workflow", "run"]) == nd and "VOIE COURTE" in msg,
         "voie courte reconnue : pas de contre-relecture exigée, pas de déploiement de preview, consigne dédiée")
ar = e["aller_retours"]
lancer("verdict", "2.0.6", "--a-reprendre", "--bloquants", "1", "--rapport", str(rap), par="relecteur")
e = etat("2.0.6")
verifier(e["etape"] == "correction" and e["aller_retours"] == ar and e["voie_courte_tours"] == 1,
         "À REPRENDRE en voie courte : hors compteur d'aller-retours")
monde(lambda m: m["prs"]["front"]["931"].update(headRefOid="fix2".ljust(40, "0")))
monde(lambda m: m["runs"]["front"].append(run("front", 3999, "fix2".ljust(40, "0"), "pull_request", "fix/2.0.6-ci-release",
                                              jobs={"quality": "success", "e2e": "success"})))
lancer("passe", "2.0.6", "--vers", "relecteur", par="dev")
lancer("verdict", "2.0.6", "--merger", "--rapport", str(rap2), par="relecteur")
e = etat("2.0.6")
verifier(e["etape"] == "ci-release" and e["attente"]["depots"] == ["back", "front"] and e["voie_courte_tours"] == 0,
         "correctif mergé : la CI de la release est attendue sur le front et sur le back, pas encore vu vert")
modifier_etat("2.0.6", lambda e: e.update(etape="correction", tour="dev"))
pr_correctif(932, ["tests/unit/a.test.ts", "src/app/calcul.ts"], "fix3")
monde(lambda m: m["prs"]["front"].pop("931"))
out = lancer("passe", "2.0.6", "--vers", "relecteur", par="dev", attendu=2)
verifier("--contre-relecture" in out, "un fichier d'application dans le correctif : voie normale, contre-relecture exigée")

print("18. relais : réveil ciblé quand la CI est verte et que la main n'est pas passée")
F7 = FIL.replace("000100", "000700")
nouveau_lot("2.0.8", 841, 941)
lancer("debut", "2.0.8", "--session-key", F7, par="dev")
lancer("veille")
n0 = len(monde().get("reveils", []))
modifier_etat("2.0.8", lambda e: e.update(depuis=il_y_a(20)))
lancer("veille")
r = derniers_reveils()[0]
verifier(len(monde()["reveils"]) == n0 + 1 and "Réveil ciblé n°1" in r["message"] and "cycle-lot passe 2.0.8" in r["message"]
         and r["sessionKey"] == F7, "CI verte depuis 20 min sans job ni tour : réveil ciblé du dev, sans attendre 45 min")
modifier_etat("2.0.8", lambda e: e["relances"].update(verif_session=il_y_a(11), derniere=il_y_a(20)))
lancer("veille")
verifier(len(monde()["reveils"]) == n0 + 1, "pas de second réveil ciblé avant 45 min, ni de relance ordinaire")
modifier_etat("2.0.8", lambda e: (e["relances"].update(verif_session=il_y_a(11), derniere=il_y_a(50)),
                                  e["relances"]["ci_verte"].update(heure=il_y_a(50))))
lancer("veille")
verifier("Réveil ciblé n°2" in derniers_reveils()[0]["message"], "second réveil ciblé 45 min plus tard")
modifier_etat("2.0.8", lambda e: (e.update(depuis=il_y_a(60)),
                                  e["relances"].update(verif_session=il_y_a(11), derniere=il_y_a(50)),
                                  e["relances"]["ci_verte"].update(heure=il_y_a(50))))
lancer("veille")
verifier("Relance automatique n°1" in derniers_reveils()[0]["message"], "puis les relances ordinaires prennent le relais")
monde(lambda m: m["runs"]["front"].append(run("front", 4000, "featfront2.0.8".ljust(40, "0"), "pull_request", "feat/2.0.8-lot",
                                              concl="failure", jobs={"quality": "failure", "e2e": "success"})))
monde(lambda m: m["runs"]["front"][-1].update(createdAt="2099-01-01T00:00:00Z"))
modifier_etat("2.0.8", lambda e: e.update(depuis=il_y_a(20), relances={"nb": 0, "derniere": None, "alerte": False}))
n1 = len(monde()["reveils"])
lancer("veille")
verifier(len(monde()["reveils"]) == n1, "CI rouge sur une PR : pas de réveil ciblé")

print("19. promotion du même contenu : jobs de test sautés par décision, marqueur contenu-deja-valide")
modifier_etat("2.0.8", lambda e: e.update(etape="ci-release", tour="veille", depuis=il_y_a(1),
                                          attente={"depots": ["back"], "relances": []}))
monde(lambda m: m["runs"]["back"].append(run("back", 4100, m["refs"]["back"]["release/2.0.8"], "push", "release/2.0.8",
                                             jobs={"quality": "skipped", "integration": "skipped", "deploy": "success"})))
lancer("veille")
verifier(etat("2.0.8")["etape"] == "correction", "quality sauté sans marqueur : le run n'a rien testé, il est rouge")
modifier_etat("2.0.8", lambda e: e.update(etape="ci-release", tour="veille", depuis=il_y_a(1), ci_rouges=0,
                                          attente={"depots": ["back"], "relances": []}))
monde(lambda m: m["runs"]["back"][-1]["jobs"].update({"contenu-deja-valide": "success"}))
lancer("veille")
verifier(etat("2.0.8")["etape"] == "ci-livraison", "quality sauté avec le marqueur contenu-deja-valide : run vert")

print("20. attente sans rouge au-delà du plafond : un avis, puis l'attente continue jusqu'au double")
modifier_etat("2.0.8", lambda e: e.update(etape="deploiement", tour="veille", depuis=il_y_a(250),
                                          attente={"commits": [{"depot": "back", "base": "master", "commit": "prod108".ljust(40, "0")}],
                                                   "relances": []}))
monde(lambda m: m["runs"]["back"].append(run("back", 4200, "prod108".ljust(40, "0"), "push", "master", statut="queued", concl=None)))
na = len(monde()["avis"])
lancer("veille")
lancer("veille")
e = etat("2.0.8")
verifier(e["etape"] == "deploiement" and len(monde()["avis"]) == na + 1 and "aucun job rouge" in monde()["avis"][-1],
         "250 min sans verdict ni rouge : un seul avis, pas d'arrêt")
modifier_etat("2.0.8", lambda e: e.update(depuis=il_y_a(490)))
lancer("veille")
verifier(etat("2.0.8")["etape"] == "arret", "au double du plafond : arrêt")

print("21. réglages de déploiement : exigés avant les validations en production")
lancer("reprise", "2.0.8", "--decision", "essai", "--etape", "liste-validation", par="dev")
lancer("reglage", "2.0.8", "--ajouter", "FOO_URL sur backend-prod", par="dev")
lancer("reglage", "2.0.8", "--ajouter", "lancer republier-donnees.yml sur master", par="relecteur")
lancer("veille")
lancer("reveiller", "2.0.8", par="dev")
lancer("veille")
verifier("FOO_URL sur backend-prod" in derniers_reveils()[0]["message"] and "AVANT de passer la main" in derniers_reveils()[0]["message"],
         "liste-validation : les réglages ouverts sont dans la consigne du dev")
out = lancer("passe", "2.0.8", "--vers", "relecteur", "--etape", "validation-prod", "--fichier", str(liste), par="dev", attendu=2)
verifier("réglages de déploiement encore ouverts" in out and "republier-donnees" in out, "validation-prod refusée : réglages ouverts")
out = lancer("reglage", "2.0.8", "--fait", "1", par="dev", attendu=2)
verifier("--preuve" in out, "réglage refusé sans preuve")
lancer("reglage", "2.0.8", "--fait", "1", "--preuve", "/health : front_url présent", par="dev")
lancer("reglage", "2.0.8", "--fait", "2", "--preuve", "run 123 vert, 42 entrées", par="dev")
lancer("passe", "2.0.8", "--vers", "relecteur", "--etape", "validation-prod", "--fichier", str(liste), par="dev")
lancer("veille")
verifier(etat("2.0.8")["etape"] == "validation-prod" and "run 123 vert" in derniers_reveils()[0]["message"],
         "réglages faits et prouvés : le relecteur les vérifie en premier")

print("22. marges de CI : durée mesurée face au plafond")
WF = ("name: Back\non:\n  push:\njobs:\n  quality:\n    runs-on: x\n    timeout-minutes: 90\n    steps:\n"
      "      - name: Tests\n        timeout-minutes: 50\n        run: pytest\n  deploy:\n    timeout-minutes: 10\n    steps:\n"
      "      - uses: actions/checkout@v4\n      - name: Deploy\n        run: curl\n")


def mesures(m):
    for d in ("back", "front"):
        m["fichiers"][d].setdefault("develop", {})[f".github/workflows/{d}.yml"] = WF
    r = run("back", 5000, "mesure".ljust(40, "0"), "push", "release/2.0.8", jobs={"quality": "success", "deploy": "success"})
    r["createdAt"] = "2099-02-01T00:00:00Z"
    r["detail"] = [{"name": "quality", "conclusion": "success", "startedAt": "2030-01-10T10:00:00Z",
                    "completedAt": "2030-01-10T10:53:00Z",
                    "steps": [{"name": "Tests", "conclusion": "success", "startedAt": "2030-01-10T10:02:00Z",
                               "completedAt": "2030-01-10T10:47:00Z"}]},
                   {"name": "deploy", "conclusion": "success", "startedAt": "2030-01-10T10:53:00Z",
                    "completedAt": "2030-01-10T10:54:00Z", "steps": []}]
    m["runs"]["back"].append(r)


monde(mesures)
out = lancer("marges", "--ref", "develop", par="mainteneur")
verifier("!! quality / Tests : 45.0 min sur 50 (90 %)" in out and "   quality : 53.0 min sur 90 (59 %)" in out
         and "deploy : 1.0 min sur 10" in out, "marges : étape à 90 % de son plafond signalée, job à 59 % non")

print("13. aucune commande d'agent n'a tenté de réveil direct")
verifier(not monde().get("refus_exec"), "aucun `gateway call agent` depuis l'exec d'un agent")

print(lancer("etat", "1.0.0"))
print(f"\n{len(ECHECS)} échec(s)" if ECHECS else "\nTOUT PASSE")
for x in ECHECS:
    print("---\n" + x)
sys.exit(1 if ECHECS else 0)
