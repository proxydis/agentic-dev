#!/usr/bin/env bash
# Essai de run-reel.sh, sans Claude : un faux `claude` lit le cadre, dort 3 s et écrit sa section.
#   bash tests/essai-run-reel.sh      (sortie 0 = tout passe ; une dizaine de secondes)
set -uo pipefail
ICI=$(cd "$(dirname "$0")" && pwd)
RACINE=$(dirname "$ICI")
T=$(mktemp -d "${TMPDIR:-/tmp}/essai-run-reel-XXXXXX")
trap 'rm -rf "$T"' EXIT
ECHECS=0
verifier() { if eval "$1"; then echo "  ok   $2"; else echo "  ÉCHEC $2"; ECHECS=$((ECHECS + 1)); fi; }

mkdir -p "$T/bin" "$T/lot"
cat >"$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
# faux claude : écrit « Section <titre> » dans le fichier que le cadre lui désigne ; ECHOUE dans la consigne : rc 3
p=$(cat)
grep -q ECHOUE <<<"$p" && exit 3
section=$(grep -o "N'écris ta section que dans \`[^\`]*\`" <<<"$p" | sed "s/.*\`\(.*\)\`/\1/")
titre=$(head -n 1 <<<"$p")
sleep 3
echo "## Section $titre" >"$section"
grep -q "MetGate : 10" <<<"$p" && echo "quota vu" >>"$section"
echo "passe finie"
EOF
chmod +x "$T/bin/claude"
echo "back" >"$T/lot/step-REEL-back.md"
echo "front" >"$T/lot/step-REEL-front.md"
echo "# Preuves" >"$T/preuves.md"
export CLAUDE="$T/bin/claude" REEL_PARTAGE="MetGate : 10 consultations en tout"

echo "1. deux passes en parallèle, sections ajoutées aux preuves"
t0=$SECONDS
bash "$RACINE/run-reel.sh" "$T/lot" "$T/preuves.md" >/dev/null 2>&1
verifier '[ $? -eq 0 ]' "sortie 0"
verifier '[ $((SECONDS - t0)) -lt 6 ]' "passes simultanées (moins de 6 s pour deux passes de 3 s)"
verifier '[ "$(grep -c "^## Section" "$T/preuves.md")" -eq 2 ] && grep -n "" "$T/preuves.md" | grep -q "^[0-9]*:## Section back" && [ "$(grep -n "Section back" "$T/preuves.md" | cut -d: -f1)" -lt "$(grep -n "Section front" "$T/preuves.md" | cut -d: -f1)" ]' \
  "deux sections ajoutées, dans l'ordre des noms"
verifier 'grep -q "^# Preuves" "$T/preuves.md"' "le début du fichier des preuves est gardé"
verifier '[ "$(grep -c "quota vu" "$T/preuves.md")" -eq 2 ]' "ressources partagées citées dans le cadre de chaque passe"
verifier 'grep -q "step-REEL-front.md" "$T/lot/logs/reel-back.log" || grep -q "OK passe step-REEL-back.md" "$T/lot/logs/reel-chain.log"' "journal par passe et log de chaîne"

echo "2. une passe en échec : sortie 1, la section de l'autre ajoutée quand même"
echo "front ECHOUE" >"$T/lot/step-REEL-front.md"
echo "# Preuves" >"$T/preuves.md"
bash "$RACINE/run-reel.sh" "$T/lot" "$T/preuves.md" >/dev/null 2>&1
verifier '[ $? -eq 1 ]' "sortie 1"
verifier 'grep -q "ÉCHEC passe step-REEL-front.md : rc=3" "$T/lot/logs/reel-chain.log"' "échec écrit dans le log de chaîne"
verifier 'grep -q "Section back" "$T/preuves.md" && ! grep -q "Section front" "$T/preuves.md"' "section de la passe réussie ajoutée seule"

echo "3. aucune consigne : refusé"
rm "$T/lot"/step-REEL-*.md
bash "$RACINE/run-reel.sh" "$T/lot" >/dev/null 2>&1
verifier '[ $? -eq 1 ] && grep -q "ABANDON : aucune consigne" "$T/lot/logs/reel-chain.log"' "sortie 1, abandon écrit"

echo
[ "$ECHECS" -eq 0 ] && echo "TOUT PASSE" || echo "$ECHECS ÉCHEC(S)"
[ "$ECHECS" -eq 0 ]
