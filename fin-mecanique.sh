#!/usr/bin/env bash
# Partie mécanique d'une fin de lot, sans Claude : suite complète, lint, typage, build, e2e, audit… d'une application,
# joués en script par run-lot.sh. Une passe Claude qui garde ces commandes pour elle dure des heures et dépense des
# jetons à attendre ; ici, une passe n'est rappelée que s'il y a du rouge, avec le rapport écrit par ce script.
#
#   fin-mecanique.sh <back|front> <dépôt> <base> <dossier des journaux> [<liste des commandes>]
#
# Liste des commandes : fin-mecanique-<app>.txt à côté de ce script (exemples fournis : un back Python, un front
# Node), ou celle donnée en 5e argument (run-lot.sh passe <lot>/fin-mecanique-<app>.txt s'il existe). Une ligne par
# commande, jouées dans l'ordre, dans le dépôt ; lignes vides et lignes en # ignorées, ligne sans « | » ignorée :
#   <nom> [apres=<nom>] [sortie2=non-joue] | <commande shell>
#   apres=<nom>        sautée si la commande <nom> est rouge ou sautée (e2e après build)
#   sortie2=non-joue   une sortie 2 veut dire « n'a pas pu tourner », pas rouge (vérification qui dépend d'un service)
# Variables offertes aux commandes : $W (workers), $J (dossier des journaux), $T (dossier temporaire du passage, hors
# de /tmp et hors de tout dépôt git, effacé à la fin), $BASE, $E2E_PORT, $VERIF (VERIF_FIN de run-lot.sh).
#
# Réglages (environnement) : WORKERS (4), E2E_PORT (3123), MECA_DELAI_S (délai par commande, 5400 s), MECA_TMP (racine
# des dossiers temporaires, ~/.cache/run-lot/meca), MECA_DISQUE_MIO (disque libre exigé sous MECA_TMP, 8192 Mio).
# Toutes les commandes sont jouées, même après un rouge : la passe de correction reçoit la liste entière d'un coup.
#
# Sortie 0 : tout est vert. 1 : au moins un rouge. 2 : rien n'a pu être joué (arguments, liste absente, disque plein).
# Le rapport (Markdown) va sur la sortie standard ; chaque commande a son journal <dossier>/<nom>.log.
set -uo pipefail
APP=${1:?back ou front}
DEPOT=${2:?dossier du dépôt}
BASE=${3:?base de comparaison, origin/release/X.Y.Z}
J=${4:?dossier des journaux}
HERE=$(dirname "$(realpath "$0")")
LISTE=${5:-$HERE/fin-mecanique-$APP.txt}
W=${WORKERS:-4}
E2E_PORT=${E2E_PORT:-3123}
VERIF=${VERIF:-}
DELAI=${MECA_DELAI_S:-5400}  # par commande
[ -f "$LISTE" ] || { echo "fin-mecanique : liste absente ($LISTE)" >&2; exit 2; }
cd "$DEPOT" || { echo "fin-mecanique : dépôt introuvable ($DEPOT)" >&2; exit 2; }
mkdir -p "$J" || exit 2
J=$(realpath "$J")
# Dossier temporaire du passage : ni dans /tmp (souvent un tmpfs, vite plein), ni dans un dépôt git (des tests qui
# lancent `git ls-files` dans leur dossier temporaire y verraient le dépôt englobant et rougiraient à tort).
T=${MECA_TMP:-${XDG_CACHE_HOME:-$HOME/.cache}/run-lot/meca}/$(basename "$J")
rm -rf "$T"; mkdir -p "$T/tmp" || exit 2
T=$(realpath "$T")
trap 'rm -rf "$T"' EXIT
if git -C "$T" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "fin-mecanique : le dossier temporaire $T est dans un dépôt git (MECA_TMP) : rien n'est joué" >&2
  exit 2
fi
# Disque presque plein : une suite complète y échoue sur « No space left on device », ce qui ferait un faux rouge
# et une passe de correction pour rien. Mieux vaut ne pas partir. Une grosse suite peut occuper plusieurs Go de
# dossiers temporaires : régler MECA_DISQUE_MIO en conséquence.
libre=$(df -BM --output=avail "$T" | tail -n 1 | tr -dc 0-9)
if [ "${libre:-0}" -lt "${MECA_DISQUE_MIO:-8192}" ]; then
  echo "fin-mecanique : ${libre:-?} Mio libres sur le disque de $T, il en faut ${MECA_DISQUE_MIO:-8192} : rien n'est joué" >&2
  exit 2
fi
export W J T BASE E2E_PORT VERIF

declare -A ETAT=()
lignes=() rouges=() n=0
while IFS= read -r ligne || [ -n "$ligne" ]; do
  case $ligne in ''|'#'*) continue ;; esac
  tete=${ligne%%|*}; cmd=${ligne#*|}; cmd=${cmd# }
  [ "$tete" = "$ligne" ] && continue  # pas de « | » : ligne ignorée
  read -r nom opts <<<"$tete"
  apres=""; sortie2=""
  for o in $opts; do
    case $o in apres=*) apres=${o#apres=} ;; sortie2=non-joue) sortie2=1 ;; esac
  done
  n=$((n + 1))
  if [ -n "$apres" ] && [ "${ETAT[$apres]:-ok}" != ok ]; then
    ETAT[$nom]=saute
    lignes+=("- sautée  **$nom** : dépend de \`$apres\`, qui n'est pas vert")
    continue
  fi
  log=$J/$nom.log
  t0=$SECONDS
  timeout --kill-after=30 "$DELAI" bash -c "$cmd" >"$log" 2>&1 </dev/null
  rc=$?
  d=$((SECONDS - t0))
  if [ "$rc" -eq 0 ]; then
    ETAT[$nom]=ok
    lignes+=("- ok      **$nom** (${d} s) : \`$cmd\`")
  elif [ "$rc" -eq 2 ] && [ -n "$sortie2" ]; then
    ETAT[$nom]=ok
    lignes+=("- non joué **$nom** (${d} s, sortie 2 : la commande n'a pas pu tourner, la CI de fin de lot jugera) : \`$cmd\`, journal \`$log\`")
  else
    ETAT[$nom]=rouge
    motif="sortie $rc"; [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ] && motif="arrêtée au délai de $DELAI s"
    lignes+=("- ROUGE   **$nom** (${d} s, $motif) : \`$cmd\`, journal \`$log\`")
    rouges+=("$nom")
  fi
done <"$LISTE"
rm -rf "$T"  # dossiers temporaires de ce passage

[ "$n" -gt 0 ] || { echo "fin-mecanique : aucune commande dans $LISTE" >&2; exit 2; }
echo "## Partie mécanique de la fin de lot : $APP, tête $(git rev-parse --short HEAD 2>/dev/null) ($(git rev-parse --abbrev-ref HEAD 2>/dev/null)), $(date '+%d/%m %H:%M')"
echo
if [ ${#rouges[@]} -eq 0 ]; then echo "Verdict : **VERT** ($n commandes)."; else echo "Verdict : **ROUGE**, ${#rouges[@]} commande(s) sur $n : ${rouges[*]}."; fi
echo
echo "Jouées par le lanceur, sans Claude, dans \`$DEPOT\`, avec $W workers (\`W=$W\`, \`J=$J\`, \`T=$T\`, \`BASE=$BASE\`, \`E2E_PORT=$E2E_PORT\`) :"
echo
printf '%s\n' "${lignes[@]}"
for nom in "${rouges[@]}"; do
  echo; echo "### $nom : relevés et fin du journal"; echo
  echo '```'
  grep -aE '^(FAILED|ERROR) | FAIL  |^ *[×✗] |error TS[0-9]+' "$J/$nom.log" 2>/dev/null | cut -c1-300 | head -n 40
  echo '[…]'
  tail -n 40 "$J/$nom.log" 2>/dev/null | cut -c1-300
  echo '```'
done
[ ${#rouges[@]} -eq 0 ]
