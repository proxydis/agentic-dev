#!/usr/bin/env bash
# Essai de bout en bout de run-lot.sh, sans réseau ni Claude : deux dépôts git locaux (back, front) avec leurs remotes
# nus, un faux `claude` qui fait ce que chaque étape demande et un faux `gh` qui tient les PR et la CI.
# Durée : un peu plus d'une minute (l'étape CI de fin de lot attend 60 s avant de lire un verdict).
#   bash tests/essai-run-lot.sh      (sortie 0 = tout passe)
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
mkdir -p "$T/bin" "$T/lot" "$T/logs"
cp "$ICI/faux-run-lot/claude" "$ICI/faux-run-lot/gh" "$ICI/faux-run-lot/curl" "$T/bin/"
chmod +x "$T/bin/claude" "$T/bin/gh" "$T/bin/curl"
cp "$RACINE/run-lot.sh" "$T/run-lot.sh"  # ses créneaux (slots/) restent dans le dossier de l'essai
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
EOF
echo "1. La sécurité des utilisateurs." >"$T/regles.md"
cat >"$T/lot/lot.conf" <<EOF
VERSION=1.0.0; REL=release/1.0.0; PREFIX=essai-100
REPO_BACK=$T/back
REPO_FRONT=$T/front
LOGS=$T/logs
declare -A CARTE=([1]=k1 [2]=k2 [3]=k3)
EOF
cat >"$T/lot/etapes.txt" <<'EOF'
P1 PRE back - etude/1.0.0 release/1.0.0
A1 A back 1 feat/1.0.0-lot release/1.0.0
B1 B front 2 feat/1.0.0-lot release/1.0.0
R3 FIN back 3 feat/1.0.0-lot release/1.0.0
FINB FIN back - feat/1.0.0-lot release/1.0.0
FINF FIN front - feat/1.0.0-lot release/1.0.0
EOF
echo "Étape P1 : mesure, puis écris tes questions." >"$T/lot/step-P1.md"
for s in A1 B1 R3 FINB FINF; do echo "Étape $s : ajoute le fichier $s.txt. Base : release/1.0.0." >"$T/lot/step-$s.md"; done
echo "Carte 1 : un fichier au back." >"$T/lot/card-1.md"
echo "Carte 2 : un fichier au front." >"$T/lot/card-2.md"
echo "Carte 3 : un fichier au back, après la fusion." >"$T/lot/card-3.md"
echo "# Cadre commun (back)" >"$T/lot/common-back.md"
echo "# Cadre commun (front)" >"$T/lot/common-front.md"
export RUN_LOT_CONFIG="$T/run-lot.conf" GH_ETAT="$T/gh.json" TRELLO_ETAT="$T/trello" TRELLO_API_KEY=k TRELLO_TOKEN=t
mkdir -p "$T/trello" && for k in k1 k2 k3; do echo d4d4 >"$T/trello/$k"; done  # cartes en Not Ready
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
echo "2. impl refusé tant que les questions ne sont pas tranchées"
bash "$T/run-lot.sh" "$T/lot" impl >/dev/null 2>&1
verifier '[ $? -ne 0 ]' "run-lot impl refusé"
verifier 'grep -q "ABANDON : questions-arbitrage.md sans" "$CHAINE"' "motif : décisions absentes"
printf '## Décisions de l%sagent\n1. Seuil 5 (règle 1).\n' "'" >"$T/lot/arbitrages.md"
echo "[BLOQUANTE] 2. Faut-il un compte payant ?" >>"$T/lot/questions-arbitrage.md"
bash "$T/run-lot.sh" "$T/lot" impl >/dev/null 2>&1
verifier '[ $? -ne 0 ] && grep -q "question \[BLOQUANTE\] sans" "$CHAINE"' "question bloquante sans réponse de l'humain : refusé"
printf "## Réponses de l'humain\n2. Non.\n" >>"$T/lot/arbitrages.md"

# ---------------------------------------------------------------- lot complet
echo "3. voies A et B en parallèle, FIN, CI de fin de lot"
bash "$T/run-lot.sh" "$T/lot" impl >/dev/null 2>&1
verifier '[ $? -eq 0 ]' "run-lot impl : sortie 0"
for s in A1 B1 R3 FINB FINF; do
  verifier "grep -q 'OK étape $s : ' \"\$CHAINE\"" "étape $s poussée"
done
verifier 'grep -q "\[voie A\] === étape A1" "$CHAINE" && grep -q "\[voie B\] === étape B1" "$CHAINE"' "A1 et B1 dans leurs voies"
verifier '[ "$(git -C "$T/back" ls-remote origin refs/heads/feat/1.0.0-lot | wc -l)" -eq 1 ]' "branche du lot poussée au back"
verifier 'grep -qE "CI : PR [0-9]+ \(back\) : success" "$CHAINE" && grep -qE "CI : PR [0-9]+ \(front\) : success" "$CHAINE"' \
  "verdicts de CI des deux PR"
verifier 'grep -q "##### essai-100 terminé : A rc=0, B rc=0, FIN rc=0, CI rc=0" "$CHAINE"' "ligne de fin du lot"
verifier 'python3 -c "import json,sys; e=json.load(open(sys.argv[1])); sys.exit(any(p[\"labels\"] for p in e[\"prs\"]))" "$GH_ETAT"' \
  "étiquette ci-en-pause posée pendant le lot, retirée à la fin"
verifier 'grep -q "ci-en-pause" "$GH_ETAT"' "étiquette bien posée à un moment"
verifier 'grep -q "celle qu.utilise le relecteur" "$T/logs/essai-100-FINB.prompt.md"' "grille de revue citée dans le cadre de FIN"
verifier '! grep -q "Avant chaque poussée, lance" "$T/logs/essai-100-A1.prompt.md"' "sans VERIF : aucune vérification demandée"
verifier '[ -s "$T/logs/essai-100-passation-A1.md" ]' "note de passation écrite par la passe"
verifier '[ "$(cat "$T/trello/k1")" = b2b2 ] && [ "$(cat "$T/trello/k2")" = b2b2 ]' "Trello : cartes des voies A et B en Waiting for review"
verifier '[ "$(cat "$T/trello/k3")" = b2b2 ]' "Trello : carte placée en FIN en Waiting for review"
verifier 'awk "/Trello : carte 3 \\(k3\\) en Waiting for review/ {t = NR} /phase FIN terminée/ {f = NR} END {exit !(t && t < f)}" "$CHAINE"' \
  "carte de FIN déplacée dès la fin de sa passe, avant le balayage final"

echo
if [ "$ECHECS" -eq 0 ]; then echo "TOUT PASSE"; else echo "$ECHECS échec(s) ; journal :"; cat "$CHAINE" 2>/dev/null | tail -30; fi
[ "$ECHECS" -eq 0 ]
