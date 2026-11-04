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
    "next_pr": 500, "next_run": 9000, "units": [], "sessions": {}}, indent=1))
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
    "max_aller_retours": 3}))
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
out = lancer("passe", "1.0.0", "--vers", "relecteur", "--message", "lot fini, arbitrages A1-A3 pris", par="dev")
e = etat()
verifier(e["etape"] == "deploiement-revue" and e["tour"] == "veille", "étape deploiement-revue, le relais attend")
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

print("4. verdict À REPRENDRE")
rap = TMP / "rapport1.md"
rap.write_text("points N1 N2")
out = lancer("verdict", "1.0.0", "--a-reprendre", "--rapport", str(rap), "--cartes-ok", "1,2", par="relecteur", attendu=2)
verifier("manquent : [3, 4]" in out, "refus : cartes non classées")
out = lancer("verdict", "1.0.0", "--a-reprendre", "--rapport", str(rap), "--cartes-ok", "1,2", "--cartes-ko", "3,4", par="relecteur")
verifier(etat()["a_reveiller"]["agent"] == "dev" and len(monde().get("reveils", [])) == 1, "réveil du dev planifié, pas fait par la commande")
lancer("veille")
e = etat()
verifier(e["etape"] == "correction" and e["aller_retours"] == 1, "étape correction, aller-retour 1")
verifier([liste_de(n) for n in range(1, 5)] == ["finished", "finished", "wip", "wip"], "cartes 1-2 Finished, 3-4 WIP")
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
lancer("passe", "1.0.0", "--vers", "relecteur", "--message", "N1 N2 corrigés", par="dev")
monde(lambda m: m["runs"]["back"][-1].update(status="completed", conclusion="success"))
lancer("veille")
modifier_etat("1.0.0", lambda e: e["attente"]["deploiement"].update(vert_a=il_y_a(11)))
lancer("veille")
e = etat()
verifier(e["etape"] == "revue" and "rapport1.md" in derniers_reveils()[0]["message"], "2e revue : rappel du rapport précédent")
verifier([liste_de(n) for n in range(1, 5)] == ["finished", "finished", "review", "review"], "seules 3-4 repassent en revue")

print("5. verdict À MERGER et merges gardés")
rap2 = TMP / "rapport2.md"
rap2.write_text("tout est bon")
lancer("verdict", "1.0.0", "--merger", "--rapport", str(rap2), par="relecteur")
verifier(etat()["etape"] == "merge-lot" and all(liste_de(n) == "finished" for n in range(1, 5)), "merge-lot, cartes Finished")
out = lancer("merge", "1.0.0", "--pr", "front#401", par="relecteur", attendu=2)
verifier("back d'abord" in out, "refus : front avant back")
monde(lambda m: m["prs"]["back"]["301"].update(headRefOid="pousse-apres-revue".ljust(40, "0")))
out = lancer("merge", "1.0.0", "--pr", "back#301", par="relecteur", attendu=2)
verifier("a bougé depuis la revue" in out, "refus : tête modifiée depuis la revue")
monde(lambda m: m["prs"]["back"]["301"].update(headRefOid="featback2".ljust(40, "0")))
lancer("merge", "1.0.0", "--pr", "back#301", par="relecteur")
lancer("merge", "1.0.0", "--pr", "front#401", par="relecteur")
m = monde()
verifier(m["prs"]["back"]["301"]["methode"] == "squash" and m["prs"]["front"]["401"]["state"] == "MERGED", "PR du lot squashées")
verifier(etat()["etape"] == "ci-release", "étape ci-release : le relais attend la CI du push sur la release")

print("6. CI de la release, rouge réseau relancé une fois")


def push_release(m):
    m["refs"]["back"]["release/1.0.0"] = "mergeback301".ljust(40, "0")
    m["refs"]["front"]["release/1.0.0"] = "mergefront401".ljust(40, "0")
    m["runs"]["back"].append(run("back", 50, "mergeback301".ljust(40, "0"), "push", "release/1.0.0",
                                 jobs={"quality": "success", "deploy": "success"}))
    m["runs"]["front"].append(run("front", 51, "mergefront401".ljust(40, "0"), "push", "release/1.0.0", concl="failure",
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

print("7. PR de livraison")
lancer("intervention", "1.0.0", "--ajouter", "poser FOO sur backend-prod", par="dev")
out = lancer("ouvrir-livraison", "1.0.0", par="dev", attendu=2)
verifier("interventions de Camille encore ouvertes" in out, "refus : intervention de l'humain pas faite")
lancer("intervention", "1.0.0", "--faite", "1", par="dev")
lancer("ouvrir-livraison", "1.0.0", par="dev")
e = etat()
verifier(len(e["prs_livraison"]) == 4 and e["etape"] == "ci-livraison", "4 PR de livraison, le relais attend leur CI")
lancer("veille")
verifier(etat()["etape"] == "ci-livraison", "CI des PR vers master pas encore lancée : on attend")


def ci_master(m):
    for d, sha in (("back", "mergeback301"), ("front", "mergefront401")):
        m["runs"][d].append(run(d, 60, sha.ljust(40, "0"), "pull_request", "release/1.0.0",
                                jobs={"quality": "success", "integration": "success", "e2e": "success",
                                      "push-vert": "success", "env-parity": "success"}))


monde(ci_master)
lancer("veille")
verifier(etat()["etape"] == "revue-livraison" and derniers_reveils()[0]["accountId"] == "relecteur", "revue-livraison, relecteur réveillé")
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
monde(lambda m: m.update(units=[]))

print("10. arrêt au 3e aller-retour, reprise")
modifier_etat("1.0.1", lambda e: e.update(etape="revue", tour="relecteur", aller_retours=2))
monde(lambda m: [c.update(idList=L["review"]) for c in m["cartes"] if c["name"].startswith("[V1.0.1-")])
out = lancer("verdict", "1.0.1", "--a-reprendre", "--rapport", str(rap), "--cartes-ko", "1,2", par="relecteur")
e = etat("1.0.1")
verifier(e["etape"] == "arret" and e["arret"]["motif"] == "aller-retours", "3e À REPRENDRE : cycle arrêté")
lancer("veille")
verifier("cycle arrêté (aller-retours)" in monde()["avis"][-1] and "en mentionnant Relecteur" in monde()["avis"][-1],
         "avis d'arrêt posté pour l'humain par le relais, avec l'agent à mentionner")
out = lancer("reprise", "1.0.1", "--decision", "continue", par="dev", attendu=2)
verifier("--rallonge" in out, "reprise refusée sans rallonge")
lancer("reprise", "1.0.1", "--decision", "une correction de plus", "--rallonge", par="dev")
verifier(etat("1.0.1")["etape"] == "correction" and etat("1.0.1")["max_aller_retours"] == 4, "reprise en correction, plafond 4")

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

print("13. aucune commande d'agent n'a tenté de réveil direct")
verifier(not monde().get("refus_exec"), "aucun `gateway call agent` depuis l'exec d'un agent")

print(lancer("etat", "1.0.0"))
print(f"\n{len(ECHECS)} échec(s)" if ECHECS else "\nTOUT PASSE")
for x in ECHECS:
    print("---\n" + x)
sys.exit(1 if ECHECS else 0)
