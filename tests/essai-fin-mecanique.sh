#!/usr/bin/env bash
# Essai du passage allégé de fin-mecanique.sh (MECA_ALLEGE=1), sans réseau : un dépôt git local, une liste de commandes
# qui comptent leurs passages.   bash tests/essai-fin-mecanique.sh      (sortie 0 = tout passe ; quelques secondes)
set -uo pipefail
ICI=$(cd "$(dirname "$0")" && pwd)
M=$(dirname "$ICI")/fin-mecanique.sh
T=$(mktemp -d "${TMPDIR:-/tmp}/essai-fin-meca-XXXXXX")
trap 'rm -rf "$T"' EXIT
ECHECS=0
verifier() { if eval "$1"; then echo "  ok   $2"; else echo "  ÉCHEC $2"; ECHECS=$((ECHECS + 1)); fi; }
git init -q "$T/r" && git -C "$T/r" -c user.name=e -c user.email=e@e.test commit -q --allow-empty -m a
cat >"$T/liste.txt" <<EOF
build | test ! -f $T/build-rouge
e2e apres=build long | echo e2e >>$T/compte
EOF
meca() { MECA_DISQUE_MIO=1 MECA_TMP="$T/tmp" bash "$M" back "$T/r" origin/x "$T/j" "$T/liste.txt"; }
passages() { wc -l <"$T/compte" 2>/dev/null || echo 0; }

echo "1. premier passage : tout est joué"
meca >"$T/r1.md"; verifier '[ "$(passages)" -eq 1 ] && ! grep -q repris "$T/r1.md"' "e2e joué"
echo "2. passage allégé, même tête : e2e vert repris, pas rejoué"
MECA_ALLEGE=1 meca >"$T/r2.md"
verifier '[ "$(passages)" -eq 1 ] && grep -qF "repris  **e2e**" "$T/r2.md" && grep -q "VERT" "$T/r2.md"' "e2e repris, verdict vert"
echo "3. passage allégé, build rouge : e2e sauté, pas repris"
touch "$T/build-rouge"; MECA_ALLEGE=1 meca >"$T/r3.md"
verifier 'grep -qF "sautée  **e2e**" "$T/r3.md" && ! grep -qF "repris" "$T/r3.md" && grep -q "ROUGE" "$T/r3.md"' "e2e sauté, verdict rouge"
echo "4. passage allégé après le rouge : e2e sauté au passage d'avant, donc rejoué"
rm "$T/build-rouge"; MECA_ALLEGE=1 meca >"$T/r4.md"
verifier '[ "$(passages)" -eq 2 ] && grep -qF "ok      **e2e**" "$T/r4.md"' "e2e rejoué"
echo "5. passage allégé sur une tête qui ne descend pas de la précédente : rejoué"
git -C "$T/r" checkout -q --orphan autre && git -C "$T/r" -c user.name=e -c user.email=e@e.test commit -q --allow-empty -m b
MECA_ALLEGE=1 meca >"$T/r5.md"
verifier '[ "$(passages)" -eq 3 ] && ! grep -qF "repris" "$T/r5.md"' "e2e rejoué"
echo
[ "$ECHECS" -eq 0 ] && echo "TOUT PASSE" || echo "$ECHECS ÉCHEC(S)"
[ "$ECHECS" -eq 0 ]
