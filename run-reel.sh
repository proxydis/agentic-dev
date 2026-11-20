#!/usr/bin/env bash
# run-reel.sh : preuves en réel d'un lot ou d'une reprise, en passes Claude Code parallèles.
#
#   run-reel.sh <dossier> [<fichier des preuves>]
#
# <dossier> contient une ou plusieurs consignes step-REEL<suffixe>.md (par exemple step-REEL-back.md pour les tirages
# réels du back, step-REEL-front.md pour les parcours Playwright de la preview). Chaque consigne est une passe Claude,
# et toutes partent en même temps. Chaque passe écrit sa section dans <dossier>/reel<suffixe>.md, et elle seule :
# deux passes qui ajoutent au même fichier en même temps se marchent dessus. Quand toutes sont finies, les sections
# sont ajoutées, dans l'ordre des noms, à la fin du <fichier des preuves> s'il est donné (celui de `cycle-lot passe
# --reel`). Sortie 0 si toutes les passes ont réussi et écrit leur section, 1 sinon.
#
# Réglages (environnement) : CLAUDE (commande, `claude`), PATH_LOT (PATH des passes), REEL_LOGS (dossier des journaux,
# <dossier>/logs), REEL_TRAVAIL (dossier de travail des passes, <dossier>), REEL_PARTAGE (texte ajouté au cadre de
# chaque passe : quotas de services partagés entre les passes, par exemple « MetGate : 10 consultations en tout »).
set -uo pipefail
DOSSIER=$(realpath "${1:?dossier des consignes step-REEL*.md}")
PREUVES=${2:-}
CLAUDE=${CLAUDE:-claude}
export PATH="${PATH_LOT:-$PATH}"
LOGS=${REEL_LOGS:-$DOSSIER/logs}
TRAVAIL=${REEL_TRAVAIL:-$DOSSIER}
mkdir -p "$LOGS"
CHAIN=$LOGS/reel-chain.log
note() { echo "$(date -Is) $*" | tee -a "$CHAIN"; }

mapfile -t consignes < <(find "$DOSSIER" -maxdepth 1 -name 'step-REEL*.md' | sort)
[ ${#consignes[@]} -gt 0 ] || { note "ABANDON : aucune consigne step-REEL*.md dans $DOSSIER"; exit 1; }
[ -z "$PREUVES" ] || [ -f "$PREUVES" ] || { note "ABANDON : fichier des preuves absent ($PREUVES)"; exit 1; }

# Cadre ajouté à chaque consigne : il prime sur toute consigne contraire plus haut.
cadre() {  # <section> <autres passes>
  cat <<EOF

## Cadre d'exécution de cette passe de preuves (prime sur toute consigne contraire plus haut)

- D'autres passes de preuves tournent en même temps que toi : ${2:-aucune}. N'écris ta section que dans \`$1\`,
  jamais dans le fichier des preuves du lot : le lanceur l'y ajoutera quand toutes les passes seront finies. Ne touche
  ni aux comptes, ni aux réglages, ni aux données qu'une autre passe utilise.
- Lance en même temps les tirages et les parcours indépendants, au lieu de les enchaîner. Quand une preuve demande
  plusieurs tirages réels et qu'un cache côté serveur resservirait le premier, rends chaque tirage distinct par une
  donnée d'entrée sans effet sur le critère joué (heure de départ décalée de quelques minutes, autre nom de dossier…),
  et vérifie dans le journal qu'aucun n'est servi du cache. N'attends jamais l'expiration d'un cache.
${REEL_PARTAGE:+- Ressources partagées entre les passes : $REEL_PARTAGE}
EOF
}

declare -A PID=() SECTION=()
for c in "${consignes[@]}"; do
  suf=$(basename "$c" .md); suf=${suf#step-REEL}
  SECTION[$c]=$DOSSIER/reel$suf.md
  rm -f "${SECTION[$c]}"
  autres=$(for o in "${consignes[@]}"; do [ "$o" = "$c" ] || basename "$o"; done | tr '\n' ' ')
  log=$LOGS/reel$suf.log
  note "passe $(basename "$c") lancée (journal $log, section ${SECTION[$c]})"
  (
    cd "$TRAVAIL" || exit 1
    echo "=== début $(date -Is) ==="
    { cat "$c"; cadre "${SECTION[$c]}" "$autres"; } | $CLAUDE --permission-mode bypassPermissions --print
    rc=$?; echo; echo "=== fin $(date -Is) rc=$rc ==="; exit $rc
  ) >>"$log" 2>&1 &
  PID[$c]=$!
done

rc=0
for c in "${consignes[@]}"; do
  wait "${PID[$c]}"; r=$?
  if [ "$r" -ne 0 ]; then note "ÉCHEC passe $(basename "$c") : rc=$r"; rc=1
  elif [ ! -s "${SECTION[$c]}" ]; then note "ÉCHEC passe $(basename "$c") : section ${SECTION[$c]} absente ou vide"; rc=1
  else note "OK passe $(basename "$c")"; fi
done

if [ -n "$PREUVES" ]; then
  for c in "${consignes[@]}"; do
    [ -s "${SECTION[$c]}" ] && { echo; cat "${SECTION[$c]}"; } >>"$PREUVES"
  done
  note "sections ajoutées à $PREUVES"
fi
note "##### preuves en réel terminées : rc=$rc"
exit $rc
