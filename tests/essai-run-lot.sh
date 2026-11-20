#!/usr/bin/env bash
# Essai de bout en bout de run-lot.sh, sans réseau ni Claude : deux dépôts git locaux (back, front) avec leurs remotes
# nus, un faux `claude` qui fait ce que chaque étape demande, un faux `gh` qui tient les PR et la CI, un faux `curl`
# pour Trello. Deux lots : un premier lot à trois voies avec la fin jouée en script (relecture, partie mécanique rouge
# puis verte après une passe de correction), puis sa reprise, sans script, relue sur son seul diff.
# Durée : trois minutes environ (chaque étape CI de fin de lot attend 60 s avant de lire un verdict).
#   bash tests/essai-run-lot.sh      (sortie 0 = tout passe)
#   RUN_LOT_ESSAI=/chemin/run-lot.sh bash tests/essai-run-lot.sh    essaie une copie d'atelier avant de l'installer
set -uo pipefail
ICI=$(cd "$(dirname "$0")" && pwd)
RACINE=$(dirname "$ICI")
T=$(mktemp -d "${TMPDIR:-/tmp}/essai-run-lot-XXXXXX")
trap 'rm -rf "$T"' EXIT
ECHECS=0
verifier() {  # <condition (code de retour de la commande)> <texte>
  if eval "$1"; then echo "  ok   $2"; else echo "  ÉCHEC $2"; ECHECS=$((ECHECS + 1)); fi
}

# ---------------------------------------------------------------- dépôts, outils, lot
for app in back front; do
  git init -q --bare "$T/remote-$app.git"
  git clone -q "$T/remote-$app.git" "$T/$app" 2>/dev/null
  (cd "$T/$app" && git checkout -q -b develop && echo "# $app" >README.md && git add README.md \
    && git -c user.name=essai -c user.email=essai@example.test commit -qm init \
    && git push -q origin develop && git push -q origin develop:release/1.0.0)
done
mkdir -p "$T/bin" "$T/lot" "$T/lot-r1" "$T/logs" "$T/cycles/1.0.0" "$T/trello"
cp "$ICI/faux-run-lot/claude" "$ICI/faux-run-lot/gh" "$ICI/faux-run-lot/curl" "$T/bin/"
chmod +x "$T/bin/claude" "$T/bin/gh" "$T/bin/curl"
# le lanceur et le script de fin sont copiés : leurs créneaux (slots/) restent dans le dossier de l'essai
cp "${RUN_LOT_ESSAI:-$RACINE/run-lot.sh}" "$T/run-lot.sh"
cp "$RACINE/fin-mecanique.sh" "$T/fin-mecanique.sh"; chmod +x "$T/fin-mecanique.sh"
cat >"$T/run-lot.conf" <<EOF
PATH_LOT="$T/bin:/usr/local/bin:/usr/bin:/bin"
SEUIL_MIO=1
AGENTS_RE='^essai-aucun-agent-'
REGLES_ARBITRAGE="$T/regles.md"
NOM_DEV="Dev"
ATTENTE_ECHEC_S=1
TRELLO_LISTE_WIP=a1a1
TRELLO_LISTE_ATTENTE=b2b2
TRELLO_LISTE_FINIE=c3c3
CYCLES="$T/cycles"
MECA_TMP="$T/meca"
MECA_DISQUE_MIO=1
EOF
echo "1. La sécurité des utilisateurs." >"$T/regles.md"
cat >"$T/lot/lot.conf" <<EOF
VERSION=1.0.0; REL=release/1.0.0; PREFIX=essai-100
REPO_BACK=$T/back
REPO_FRONT=$T/front
LOGS=$T/logs
declare -A CARTE=([1]=k1 [2]=k2 [3]=k3 [4]=k4)
EOF
cat >"$T/lot/etapes.txt" <<'EOF'
P1 PRE back - etude/1.0.0 release/1.0.0
A1 A back 1 feat/1.0.0-lot release/1.0.0
B1 B front 2 feat/1.0.0-lot release/1.0.0
C1 C back 4 feat/1.0.0-lot-vC release/1.0.0
FUSIONC FIN back - feat/1.0.0-lot feat/1.0.0-lot-vC
R3 FIN back 3 feat/1.0.0-lot release/1.0.0
FINB FIN back - feat/1.0.0-lot release/1.0.0
FINF FIN front - feat/1.0.0-lot release/1.0.0
EOF
echo "Étape P1 : mesure, puis écris tes questions." >"$T/lot/step-P1.md"
for s in A1 B1 C1 R3; do echo "Étape $s : ajoute le fichier $s.txt. Base : release/1.0.0." >"$T/lot/step-$s.md"; done
echo "Étape FINB : relis le lot avant la fin." >"$T/lot/step-FINB.md"  # FINF n'a pas de step : partie mécanique seule
for c in 1 2 3 4; do echo "Carte $c : un fichier." >"$T/lot/card-$c.md"; done
echo "# Cadre commun (back)" >"$T/lot/common-back.md"
echo "# Cadre commun (front)" >"$T/lot/common-front.md"
export RUN_LOT_CONFIG="$T/run-lot.conf" GH_ETAT="$T/gh.json" TRELLO_ETAT="$T/trello" TRELLO_API_KEY=k TRELLO_TOKEN=t
# partie mécanique du back : rouge tant que corrige.txt manque (le faux claude le crée en lisant le rapport)
cat >"$T/lot/fin-mecanique-back.txt" <<'EOC'
# liste de l'essai
fichiers long | test -f A1.txt && test -f C1.txt && test -f R3.txt && [ "$W" = 4 ]
correction | test -f corrige.txt || { echo "Pour passer au vert : ajoute le fichier corrige.txt. Base : release/1.0.0."; exit 1; }
suite apres=correction | true
verif sortie2=non-joue | exit 2
EOC
echo 'fichiers | test -f B1.txt' >"$T/lot/fin-mecanique-front.txt"
for k in k1 k2 k3 k4; do echo d4d4 >"$T/trello/$k"; done  # cartes en Not Ready
CHAINE_PRE=$T/logs/essai-100-pre-chain.log
CHAINE=$T/logs/essai-100-impl-chain.log

# ---------------------------------------------------------------- phase PRE
echo "1. phase PRE : questions d'arbitrage, règles du projet dans le cadre"
bash "$T/run-lot.sh" "$T/lot" pre >/dev/null 2>&1
verifier '[ $? -eq 0 ]' "run-lot pre : sortie 0"
verifier 'grep -q "OK étape P1 : rien à pousser" "$CHAINE_PRE"' "étape PRE sans poussée acceptée"
verifier 'grep -q "1. La sécurité des utilisateurs." "$T/logs/essai-100-P1.prompt.md"' "règles d'arbitrage dans le cadre de la passe PRE"
verifier 'grep -q "Dev les" "$T/logs/essai-100-P1.prompt.md"' "nom de l'agent développeur pris dans la config"
verifier '[ -s "$T/lot/questions-arbitrage.md" ] && grep -q "ARBITRAGES EN ATTENTE" "$CHAINE_PRE"' "questions écrites, signalées en fin de PRE"

# ---------------------------------------------------------------- garde des arbitrages
echo "2. impl refusé : arbitrages non tranchés, puis deux voies sur la même branche"
bash "$T/run-lot.sh" "$T/lot" impl >/dev/null 2>&1
verifier '[ $? -ne 0 ]' "run-lot impl refusé"
verifier 'grep -q "ABANDON : questions-arbitrage.md sans" "$CHAINE"' "motif : décisions absentes"
printf '## Décisions de l%sagent\n1. Seuil 5 (règle 1).\n' "'" >"$T/lot/arbitrages.md"
echo "[BLOQUANTE] 2. Faut-il un compte payant ?" >>"$T/lot/questions-arbitrage.md"
bash "$T/run-lot.sh" "$T/lot" impl >/dev/null 2>&1
verifier '[ $? -ne 0 ] && grep -q "question \[BLOQUANTE\] sans" "$CHAINE"' "question bloquante sans réponse de l'humain : refusé"
printf "## Réponses de l'humain\n2. Non.\n" >>"$T/lot/arbitrages.md"
sed -i 's#^C1 C back 4 feat/1.0.0-lot-vC#C1 C back 4 feat/1.0.0-lot#' "$T/lot/etapes.txt"
bash "$T/run-lot.sh" "$T/lot" impl >/dev/null 2>&1
verifier '[ $? -ne 0 ] && grep -q "ABANDON : deux voies sur la même branche" "$CHAINE"' "voies A et C sur la même branche du back : refusé"
sed -i 's#^C1 C back 4 feat/1.0.0-lot #C1 C back 4 feat/1.0.0-lot-vC #' "$T/lot/etapes.txt"

# ---------------------------------------------------------------- lot complet
echo "3. voies A, B et C en parallèle, fusion, fin jouée en script, CI de fin de lot"
bash "$T/run-lot.sh" "$T/lot" impl >/dev/null 2>&1
verifier '[ $? -eq 0 ]' "run-lot impl : sortie 0"
for s in A1 B1 C1 R3 FINB FINB-c1; do
  verifier "grep -q 'OK étape $s : ' \"\$CHAINE\"" "étape $s : passe Claude poussée"
done
verifier 'grep -q "\[voie A\] === étape A1" "$CHAINE" && grep -q "\[voie B\] === étape B1" "$CHAINE" && grep -q "\[voie C\] === étape C1" "$CHAINE"' "A1, B1 et C1 dans leurs voies"
verifier '[ -d "$T/back-wt-essai-100-vC" ]' "voie C sur le dépôt de la voie A : worktree dédié"
verifier 'grep -q "OK FUSIONC : feat/1.0.0-lot-vC fusionnée" "$CHAINE"' "branche de la voie C fusionnée en FIN"
verifier 'grep -q "Au plus 2 workers" "$T/logs/essai-100-A1.prompt.md"' "trois voies : 2 workers de tests ciblés par voie"
verifier 'grep -q "jamais la suite complète" "$T/logs/essai-100-R3.prompt.md" && ! grep -q "Passe de fin" "$T/logs/essai-100-R3.prompt.md"' \
  "carte placée en FIN avant la fin de l'appli : tests ciblés seulement"
verifier 'grep -q "Passe de fin, relecture" "$T/logs/essai-100-FINB.prompt.md" && grep -q "ne se lancent PAS dans cette passe" "$T/logs/essai-100-FINB.prompt.md"' \
  "FINB : passe de relecture, sans la suite complète"
verifier 'grep -qF "git diff origin/release/1.0.0...HEAD" "$T/logs/essai-100-FINB.prompt.md"' "premier lot : relecture du diff complet du lot"
verifier 'grep -q "étape FINB : partie mécanique ROUGE" "$CHAINE" && grep -q "1 commande(s) sur 4 : correction" "$CHAINE"' "partie mécanique du back : rouge au premier passage"
verifier 'grep -q "Passe de fin, correction" "$T/logs/essai-100-FINB-c1.prompt.md" && grep -qF "ROUGE   **correction**" "$T/logs/essai-100-FINB-c1.prompt.md"' \
  "passe de correction : cadre et rapport du rouge en tête"
verifier 'grep -qF "sautée  **suite**" "$T/logs/essai-100-FINB-meca-1.md" && grep -qF "non joué **verif**" "$T/logs/essai-100-FINB-meca-1.md"' \
  "rapport : commande dépendante sautée, sortie 2 comptée non jouée"
verifier 'grep -q "OK étape FINB : partie mécanique verte" "$CHAINE"' "partie mécanique du back : verte après la correction"
verifier 'grep -qF "repris  **fichiers**" "$T/logs/essai-100-FINB-meca-2.md" && grep -qF "ok      **correction**" "$T/logs/essai-100-FINB-meca-2.md" && ! grep -qF "repris" "$T/logs/essai-100-FINB-meca-1.md"' \
  "passage allégé après correction : commande longue verte reprise, la rouge rejouée (piste A)"
verifier 'grep -q "phase FIN en 2 files parallèles" "$CHAINE" && grep -q "\[voie FIN-back\]" "$CHAINE" && grep -q "\[voie FIN-front\]" "$CHAINE"' \
  "phase FIN en deux files, une par dépôt (piste B)"
verifier '[ "$(grep -c "=== étape FIN.*partie mécanique sans Claude" "$CHAINE")" -ge 3 ] && python3 -I "$ICI/meca-sequentielles.py" "$CHAINE"' \
  "parties mécaniques jamais simultanées entre les deux files"
verifier '[ -n "$(git -C "$T/back" ls-tree -r --name-only origin/feat/1.0.0-lot | grep -x corrige.txt)" ]' "correction poussée sur la branche du lot"
verifier 'grep -q "pas de step-FINF.md" "$CHAINE" && grep -q "OK étape FINF : partie mécanique verte" "$CHAINE" && [ ! -e "$T/logs/essai-100-FINF.prompt.md" ]' \
  "FINF sans step et verte : aucune passe Claude"
verifier '! grep -q "reprise (" "$CHAINE"' "premier lot : pas traité comme une reprise"
verifier 'grep -qE "CI : PR [0-9]+ \(back\) : success" "$CHAINE" && grep -qE "CI : PR [0-9]+ \(front\) : success" "$CHAINE"' \
  "verdicts de CI des deux PR"
verifier 'grep -q "##### essai-100 terminé : A rc=0, B rc=0, C rc=0, FIN rc=0, CI rc=0" "$CHAINE"' "ligne de fin du lot"
verifier 'python3 -I -c "import json,sys; e=json.load(open(sys.argv[1])); sys.exit(any(p[\"labels\"] for p in e[\"prs\"]))" "$GH_ETAT"' \
  "étiquette ci-en-pause retirée à la fin"
verifier '[ "$(grep -c "rouverte sans ci-en-pause" "$CHAINE")" = 2 ]' "CI de fin : une PR par appli, la branche -vC n'en a pas"
verifier '[ -s "$T/logs/essai-100-passation-A1.md" ]' "note de passation écrite par la passe"
verifier '[ "$(cat "$T/trello/k1")" = b2b2 ] && [ "$(cat "$T/trello/k2")" = b2b2 ] && [ "$(cat "$T/trello/k3")" = b2b2 ]' \
  "Trello : cartes des voies A et B et carte de FIN en Waiting for review"
verifier '[ "$(cat "$T/trello/k4")" = b2b2 ]' "Trello : carte de la voie C en Waiting for review après la fusion"
verifier 'grep -q "ci-en-pause" "$GH_ETAT"' "étiquette bien posée à un moment"
verifier 'grep -q "celle qu.utilise le relecteur" "$T/logs/essai-100-FINB.prompt.md"' "grille de revue citée dans le cadre de la relecture"
verifier '! grep -q "Avant chaque poussée, lance" "$T/logs/essai-100-A1.prompt.md"' "sans VERIF : aucune vérification demandée"
verifier 'awk "/Trello : carte 3 \\(k3\\) en Waiting for review/ {t = NR} /phase FIN terminée/ {f = NR} END {exit !(t && t < f)}" "$CHAINE"' \
  "carte de FIN déplacée dès la fin de sa passe, avant le balayage final"

# ---------------------------------------------------------------- reprise : relecture du seul diff, sans script
echo "4. reprise après un verdict À REPRENDRE : deux voies, relecture limitée au diff de la reprise"
AVANT=$(git -C "$T/back" ls-remote origin refs/heads/feat/1.0.0-lot | cut -f1)
echo '{"aller_retours": 1, "etape": "correction"}' >"$T/cycles/1.0.0/etat.json"
sed 's/PREFIX=essai-100/PREFIX=essai-100r1/' "$T/lot/lot.conf" >"$T/lot-r1/lot.conf"
cat >"$T/lot-r1/etapes.txt" <<'EOC'
RA A back 1 feat/1.0.0-lot release/1.0.0
RB B front 2 feat/1.0.0-lot release/1.0.0
FINB FIN back - feat/1.0.0-lot release/1.0.0
EOC
for s in RA RB; do echo "Étape $s : ajoute le fichier $s.txt. Base : release/1.0.0." >"$T/lot-r1/step-$s.md"; done
echo "Étape FINB : contre-relecture de la reprise." >"$T/lot-r1/step-FINB.md"
cp "$T/lot/card-1.md" "$T/lot/card-2.md" "$T/lot/common-back.md" "$T/lot/common-front.md" "$T/lot-r1/"
CHAINE_R=$T/logs/essai-100r1-impl-chain.log
MECA="" bash "$T/run-lot.sh" "$T/lot-r1" impl >/dev/null 2>&1
verifier '[ $? -eq 0 ]' "run-lot impl de la reprise : sortie 0"
verifier 'grep -q "reprise (back) : tête d.avant ${AVANT:0:9}" "$CHAINE_R"' "reprise reconnue par l'état du cycle, tête d'avant notée"
verifier 'grep -qF "git diff $AVANT..HEAD" "$T/logs/essai-100r1-FINB.prompt.md" && ! grep -qF "git diff origin/release/1.0.0...HEAD" "$T/logs/essai-100r1-FINB.prompt.md"' \
  "relecture limitée au diff de la reprise"
verifier 'grep -q "avec au plus 4 workers" "$T/logs/essai-100r1-FINB.prompt.md" && ! grep -q "partie mécanique" "$CHAINE_R"' \
  "sans script (MECA vide) : la passe FIN lance la suite, à 4 workers"
verifier 'grep -q "Au plus 4 workers" "$T/logs/essai-100r1-RA.prompt.md"' "deux voies : 4 workers par voie"
verifier 'grep -q "##### essai-100r1 terminé : A rc=0, B rc=0, FIN rc=0, CI rc=0" "$CHAINE_R"' "ligne de fin de la reprise, sans voie C"

echo
if [ "$ECHECS" -eq 0 ]; then echo "TOUT PASSE"; else echo "$ECHECS échec(s) ; journaux :"; tail -n 40 "$CHAINE" 2>/dev/null; tail -n 15 "${CHAINE_R:-/dev/null}" 2>/dev/null; fi
[ "$ECHECS" -eq 0 ]
