#!/usr/bin/env bash
# run-lot.sh : lanceur d'un lot de cartes pour un agent de développement, en passes Claude Code non interactives.
# Mode d'emploi : README.md. Réglages de la machine : run-lot.conf à côté de ce script (modèle : run-lot.example.conf),
# ou le fichier désigné par RUN_LOT_CONFIG.
#
#   run-lot.sh <dossier-du-lot> pre    phase PRE seule (études, mesures, questions d'arbitrage), puis s'arrête
#   run-lot.sh <dossier-du-lot> impl   voies A, B et C en parallèle, phase FIN (fusion, relecture, puis suite
#                                      complète et contrôles joués en script, sans Claude), puis CI des PR du
#                                      lot, une fois, sur leurs têtes finales
#
# Le dossier du lot contient lot.conf, etapes.txt, step-<nom>.md, card-<nn>.md, arbitrages.md,
# common-back.md, common-front.md (et common-<suffixe de branche>.md s'il le faut).
# Ligne d'etapes.txt :  <nom> <phase> <repo> <cartes|-> <branche> <base> [opt]
#   phase = PRE | A | B | C | FIN ; une étape FUSION (nom commençant par FUSION) fusionne la branche d'une voie
#   (-vB, -vC) dans celle du lot, la résolution des conflits passant par Claude si git n'y arrive pas seul.
#   Une étape FIN sans carte est la fin d'une application : relecture par Claude si step-<nom>.md existe, puis
#   partie mécanique (fin-mecanique.sh), puis une passe de correction seulement s'il y a du rouge.
set -uo pipefail

LOT=$(realpath "${1:?dossier du lot}")
MODE=${2:?pre ou impl}
HERE=$(dirname "$(realpath "$0")")
# shellcheck source=/dev/null
[ -f "${RUN_LOT_CONFIG:-$HERE/run-lot.conf}" ] && source "${RUN_LOT_CONFIG:-$HERE/run-lot.conf}"
# shellcheck source=/dev/null
source "$LOT/lot.conf"
: "${VERSION:?}" "${REL:?}" "${PREFIX:?}" "${REPO_BACK:?}" "${REPO_FRONT:?}" "${LOGS:?}"
declare -p CARTE >/dev/null 2>&1 || declare -A CARTE=()
# Au plus MAX_VOIES passes Claude Code à la fois, SEUIL_MIO de mémoire disponible exigés au démarrage de chaque passe.
# À trois voies, chaque voie n'a que WORKERS_3VOIES workers de tests ciblés.
MAX_VOIES=${MAX_VOIES:-3}
SEUIL_MIO=${SEUIL_MIO:-2560}
WORKERS_VOIE=${WORKERS_VOIE:-4}
WORKERS_3VOIES=${WORKERS_3VOIES:-2}
# Fin de lot : WORKERS_FIN workers pour la suite complète (trop de workers font passer la machine en swap, et la suite
# dure plus longtemps qu'avec moins) ; partie mécanique jouée en script par MECA (MECA vide : la passe Claude de fin
# lance elle-même la suite) ; au plus MAX_TOURS_FIN passages de cette partie.
WORKERS_FIN=${WORKERS_FIN:-4}
MECA=${MECA-$HERE/fin-mecanique.sh}
MAX_TOURS_FIN=${MAX_TOURS_FIN:-3}
# Fin de lot plus courte :
# A. après une passe de correction, la partie mécanique ne rejoue pas les commandes longues déjà vertes (MECA_ALLEGE,
#    option `long` de fin-mecanique-<app>.txt) ; la CI de fin de lot les rejoue de toute façon.
# B. la phase FIN suit deux files en parallèle, une par dépôt (FUSION, cartes et FINB côté back ; FINF côté front) :
#    les passes Claude se chevauchent, les parties mécaniques passent une à la fois (verrou du lot), parce que la
#    suite complète d'une appli et les e2e de l'autre, ensemble, dépassent vite la mémoire d'une petite machine.
#    FIN_PARALLELE=0 : une seule file, comme avant.
FIN_PARALLELE=${FIN_PARALLELE:-1}
# Reprise : tête de la branche du lot avant la reprise (la relecture de fin se limite au diff depuis cette tête).
# Dans un cycle de lot, elle est notée toute seule au premier lancement d'un PREFIX quand le cycle est en correction
# (un verdict À REPRENDRE a été rendu) ; hors cycle, la donner dans lot.conf. « - » force la relecture du lot entier.
CYCLES=${CYCLES:-$HERE/cycles}
REPRISE_DEPUIS_BACK=${REPRISE_DEPUIS_BACK:-}
REPRISE_DEPUIS_FRONT=${REPRISE_DEPUIS_FRONT:-}
CLAUDE=${CLAUDE:-claude}
export PATH="${PATH_LOT:-$PATH}"
export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0
mkdir -p "$LOGS"
CHAIN=$LOGS/$PREFIX-$MODE-chain.log
FAITES=$LOGS/$PREFIX-faites.txt
ETAPES=$LOT/etapes.txt
SLOTS=$HERE/slots; mkdir -p "$SLOTS"
SELF=$(cat /proc/self/cgroup 2>/dev/null | sed -n 's#.*/app.slice/\([^/]*\.service\).*#\1#p')
APP_SLICE=/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/app.slice
# Units systemd des agents (préfixe <agent>-) comptées comme jobs lourds extérieurs quand elles chargent la machine.
AGENTS_RE=${AGENTS_RE:-'^(dev|relecteur)[-0-9]'}
# CI pendant un lot : la CI des PR reste en pause (étiquette) jusqu'à la fin du lot, puis tourne une fois. Les passes
# peuvent lancer une vérification avant de pousser (VERIF pendant les voies, VERIF_FIN en passe FIN), appelée avec
# le dossier du dépôt et la base de comparaison : sortie 0 rien à corriger, 1 à corriger, 2 n'a pas pu tourner.
VERIF=${VERIF:-}
VERIF_FIN=${VERIF_FIN:-$VERIF}
PAUSE=${PAUSE_CI:-ci-en-pause}
WORKFLOW_BACK=${WORKFLOW_BACK:-back.yml}
WORKFLOW_FRONT=${WORKFLOW_FRONT:-front.yml}
# Rouge sans rapport avec le code (Sonar côté serveur, coupure réseau) : jobs rouges relancés une fois en fin de lot.
MOTIFS_NON_CODE=${MOTIFS_NON_CODE:-'CE Task finished abnormally|ECONNRESET|ETIMEDOUT|EAI_AGAIN|ENOTFOUND|ERR_PNPM_META_FETCH_FAIL|ERR_PNPM_FETCH_|ERR_SOCKET_TIMEOUT|UND_ERR_CONNECT_TIMEOUT|socket hang up|self-installer exits with code|HttpClient\.Timeout'}
INSTALL_BACK=${INSTALL_BACK:-uv sync -q --all-groups}
INSTALL_FRONT=${INSTALL_FRONT:-pnpm install -s --frozen-lockfile}
SUITE_FIN=${SUITE_FIN:-"tests, lint, typage, build et e2e complets de chaque application touchée"}
GRILLE=${GRILLE:-$HERE/GRILLE-REVUE.md}
REGLES_ARBITRAGE=${REGLES_ARBITRAGE:-$HERE/regles-arbitrage.md}
NOM_DEV=${NOM_DEV:-"l'agent développeur"}
NOM_REV=${NOM_REV:-"le relecteur"}
NOM_HUMAIN=${NOM_HUMAIN:-"l'humain"}
TITRE_DECISIONS=${TITRE_DECISIONS:-"Décisions de l'agent"}
TITRE_REPONSES=${TITRE_REPONSES:-"Réponses de l'humain"}
E2E_PORT_A=${E2E_PORT_A:-3123}
E2E_PORT_B=${E2E_PORT_B:-3124}
E2E_PORT_C=${E2E_PORT_C:-3125}
# Attente avant de rejouer une passe qui a échoué en moins de 10 min (panne de quota, réseau…).
ATTENTE_ECHEC_S=${ATTENTE_ECHEC_S:-1200}

note() { echo "$(date -Is) ${VOIE:+[voie $VOIE] }$*" | tee -a "$CHAIN"; }

[ -f "$LOT/NE-PAS-LANCER" ] && { note "ABANDON : $LOT/NE-PAS-LANCER présent"; exit 1; }
for d in "$REPO_BACK" "$REPO_FRONT"; do
  git -C "$d" ls-remote --exit-code --heads origin "$REL" >/dev/null || { note "ABANDON : $REL absente de $d"; exit 1; }
done

# Job lourd = unit dont le cgroup contient autre chose que des veilleurs (bash, sleep, gh…) : filtrer par nom seul
# attrapait aussi les lanceurs en attente des autres agents, qui ne chargent rien. ssh compte comme veilleur : un tunnel
# ne charge pas cette machine.
job_lourd() {
  local f=$APP_SLICE/$1/cgroup.procs procs
  [ -r "$f" ] || return 1
  procs=$(/usr/bin/cat "$f" | xargs -r ps -o comm= -p 2>/dev/null | grep -vxE 'bash|sh|sleep|gh|systemctl|timeout|grep|awk|sed|jq|date|tail|cat|comm|find|sort|xargs|ls|openclaw|curl|python3|flock|git|ssh')
  [ -n "$procs" ]
}
jobs_lourds_externes() {
  local u n=0
  for u in $(systemctl --user list-units '*.service' --state=active --no-legend --plain 2>/dev/null | awk '{print $1}' \
             | grep -E "$AGENTS_RE" | grep -vx "${SELF:-//}"); do
    # une autre instance de ce lanceur tient déjà ses créneaux flock : ne pas la compter deux fois
    /usr/bin/cat "$APP_SLICE/$u/cgroup.procs" 2>/dev/null \
      | xargs -r -I{} /usr/bin/cat /proc/{}/cmdline 2>/dev/null | tr '\0' ' ' | grep -q run-lot.sh && continue
    # job de données (<agent>-data-*) : il tourne seul, il prend tous les créneaux dès qu'il est actif,
    # même pendant son attente, pour qu'aucune passe neuve ne démarre et ne l'affame
    case $u in *-data-*) n=$((n + MAX_VOIES)); continue ;; esac
    job_lourd "$u" && n=$((n + 1))
  done
  echo "$n"
}

# Créneau Claude : au plus MAX_VOIES passes Claude à la fois sur la machine, tous lots et agents confondus
# (verrous flock partagés dans slots/). Un job lourd extérieur occupe un créneau. Puis seuil mémoire par passe.
prendre_creneau() {
  local n=0 i ext
  while :; do
    ext=$(jobs_lourds_externes)
    for ((i = 1; i <= MAX_VOIES - ext; i++)); do
      exec {FD_SLOT}>"$SLOTS/creneau-$i.lock"
      if flock -n "$FD_SLOT"; then
        CRENEAU=$i
        local dispo
        dispo=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
        if [ "$dispo" -ge "$SEUIL_MIO" ]; then note "créneau $i pris, mémoire OK : $dispo Mio"; return 0; fi
        flock -u "$FD_SLOT"; exec {FD_SLOT}>&-
        [ $((n % 10)) -eq 0 ] && note "attente mémoire : $dispo Mio (seuil $SEUIL_MIO)"
        break
      fi
      exec {FD_SLOT}>&-
    done
    n=$((n + 1))
    [ "$n" -ge 360 ] && { note "ABANDON : aucun créneau ou mémoire insuffisante depuis 6 h"; return 1; }
    [ $((n % 15)) -eq 1 ] && note "attente d'un créneau Claude ($ext job(s) lourd(s) extérieur(s), $MAX_VOIES créneaux)"
    sleep 60
  done
}
rendre_creneau() { [ -n "${FD_SLOT:-}" ] && { flock -u "$FD_SLOT"; exec {FD_SLOT}>&-; }; FD_SLOT=; }

workflow_de() { if [ "$1" = front ]; then echo "$WORKFLOW_FRONT"; else echo "$WORKFLOW_BACK"; fi; }

# PR du lot : une par application, de la branche des étapes A, B, C et FIN vers $REL (une branche -vB ou -vC n'en
# a pas, son contenu arrive par FUSION). Une ligne par PR ouverte : <dossier du dépôt> <numéro> <branche> <workflow>.
prs_du_lot() {
  local repo br dir n
  grep -vE '^[[:space:]]*(#|$)' "$ETAPES" | awk '$2 ~ /^(A|B|C|FIN)$/ {print $3, $5}' | sort -u \
    | while read -r repo br; do
        case $br in *-v[B-Z]) continue ;; esac
        dir=$REPO_BACK; [ "$repo" = front ] && dir=$REPO_FRONT
        n=$(cd "$dir" && gh pr list --head "$br" --base "$REL" --state open --json number --jq '.[0].number // empty' 2>/dev/null)
        if [ -n "$n" ]; then echo "$dir $n $br $(workflow_de "$repo")"; fi
      done
}

# CI en pause pendant le lot : l'étiquette fait sauter les jobs de PR de la CI (leur `if:` la teste), et un run
# parti avant elle, à l'ouverture de la PR par une passe, est annulé.
ci_pause() {
  local dir n br wf id
  prs_du_lot | while read -r dir n br wf; do
    (cd "$dir" && gh pr edit "$n" --add-label "$PAUSE" >/dev/null 2>&1) || note "CI : étiquette $PAUSE non posée sur la PR $n ($dir)"
    for id in $(cd "$dir" && gh run list --workflow "$wf" --branch "$br" --event pull_request --limit 20 \
                  --json databaseId,status --jq '.[] | select(.status != "completed") | .databaseId' 2>/dev/null); do
      (cd "$dir" && gh run cancel "$id" >/dev/null 2>&1) && note "CI : run $id de la PR $n annulé (lot en cours)"
    done
  done
}

# Fin de lot : la CI des PR tourne une fois, sur leurs têtes finales, et aucune passe Claude ne
# l'attend. Le lanceur retire l'étiquette, rouvre les PR (le back n'écoute pas `synchronize`, et la tête du
# front a été poussée sous l'étiquette), attend les verdicts et les écrit dans le log de chaîne : le hook
# job-done les remet à l'agent. Une tâche Sonar tombée côté serveur est relancée une fois.
ci_fin() {
  local lignes l dir n br wf sha run id statut concl rouges t0 rc=0
  mapfile -t lignes < <(prs_du_lot)
  [ ${#lignes[@]} -eq 0 ] && { note "CI : aucune PR ouverte vers $REL pour ce lot, rien à lancer"; return 0; }
  # marqueur pour d'éventuels hooks de runner auto-hébergé : ils peuvent refuser les runs d'un lot en cours, sauf
  # pendant cette étape
  : >"$LOT/.ci-fin"
  t0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  for l in "${lignes[@]}"; do
    read -r dir n br wf <<<"$l"
    (cd "$dir" && gh pr edit "$n" --remove-label "$PAUSE" >/dev/null 2>&1)
    if (cd "$dir" && gh pr close "$n" >/dev/null 2>&1 && gh pr reopen "$n" >/dev/null 2>&1); then
      note "CI : PR $n ($(basename "$dir")) rouverte sans $PAUSE, run attendu"
    else
      note "CI : réouverture de la PR $n impossible ($dir)"; rc=1
    fi
  done
  local -A verdict=() relance=()
  local fin=$((SECONDS + 10800))
  while [ "${#verdict[@]}" -lt "${#lignes[@]}" ] && [ "$SECONDS" -lt "$fin" ]; do
    sleep 60
    for l in "${lignes[@]}"; do
      read -r dir n br wf <<<"$l"
      [ -n "${verdict[$n]:-}" ] && continue
      sha=$(cd "$dir" && gh pr view "$n" --json headRefOid --jq .headRefOid 2>/dev/null) || continue
      run=$(cd "$dir" && gh run list --workflow "$wf" --branch "$br" --event pull_request --limit 10 \
              --json databaseId,headSha,status,conclusion,createdAt \
              --jq "map(select(.headSha == \"$sha\" and .createdAt >= \"$t0\")) | first | \"\(.databaseId) \(.status) \(.conclusion)\"" 2>/dev/null)
      read -r id statut concl <<<"$run"
      # PR en conflit avec la release : GitHub ne crée pas de run `pull_request`, inutile d'attendre 3 h
      if [ "${id:-null}" = null ]; then
        if [ "$(cd "$dir" && gh pr view "$n" --json mergeable --jq .mergeable 2>/dev/null)" = CONFLICTING ]; then
          verdict[$n]=conflit
          note "CI : PR $n ($(basename "$dir")) en conflit avec $REL, aucun run ne part : mettre $br à jour avec origin/$REL, puis relancer l'étape CI (reprise du lot)"
          rc=1
        fi
        continue
      fi
      [ "$statut" = completed ] || continue
      # relance unique d'un rouge qui ne juge pas le code : tâche Sonar tombée côté serveur, runner à court de
      # ressources, ou coupure réseau pendant un téléchargement (pnpm, registre npm, actions)
      if [ "$concl" = failure ] && [ -z "${relance[$n]:-}" ] \
         && (cd "$dir" && gh run view "$id" --log-failed 2>/dev/null | grep -qE "$MOTIFS_NON_CODE"); then
        relance[$n]=1
        (cd "$dir" && gh run rerun "$id" --failed >/dev/null 2>&1) && note "CI : PR $n, rouge sans rapport avec le code (run $id : Sonar côté serveur, ressources ou réseau), jobs rouges relancés une fois"
        continue
      fi
      [ "$concl" = cancelled ] && continue  # remplacé par un run plus récent sur la même tête
      verdict[$n]=$concl
      rouges=""
      [ "$concl" = success ] || rouges=$(cd "$dir" && gh run view "$id" --json jobs --jq '[.jobs[] | select(.conclusion == "failure") | .name] | join(", ")' 2>/dev/null)
      # run aux jobs sautés : il n'a rien testé (étiquette remise entre-temps ?), ce n'est jamais un vert
      [ "$concl" = skipped ] && rouges="aucun, jobs sautés : la PR porte-t-elle encore $PAUSE ?"
      note "CI : PR $n ($(basename "$dir")) : $concl, run $id${rouges:+, jobs rouges : $rouges}"
      [ "$concl" = success ] || rc=1
    done
  done
  [ "${#verdict[@]}" -lt "${#lignes[@]}" ] && { note "CI : pas de verdict en 3 h pour toutes les PR"; rc=1; }
  rm -f "$LOT/.ci-fin"
  return $rc
}

# Lot interrompu avant sa fin : la CI ne reste pas en pause, mais rien n'est relancé (l'agent décide).
ci_reprise() {
  local dir n br wf
  prs_du_lot | while read -r dir n br wf; do
    (cd "$dir" && gh pr edit "$n" --remove-label "$PAUSE" >/dev/null 2>&1) && note "CI : étiquette $PAUSE retirée de la PR $n, sans relance"
  done
}

# Trello (facultatif : listes vides = aucun déplacement) : toutes les cartes en Work in progress au démarrage, chacune
# en Waiting for review dès que sa passe est poussée dans la PR du lot. Une carte en Finished (validée par le
# relecteur) ne bouge plus : une reprise ne la rouvre pas.
LISTE_WIP=${TRELLO_LISTE_WIP:-}
LISTE_ATTENTE=${TRELLO_LISTE_ATTENTE:-}
LISTE_FINIE=${TRELLO_LISTE_FINIE:-}
trello_vers() {  # <clé de carte> <id de liste> <nom de liste>
  local id=${CARTE[$1]:-} actuelle
  [ -n "$id" ] && [ -n "$2" ] || return 0
  # sans les --setenv=TRELLO_* du lancement, le déplacement sautait sans laisser de trace
  [ -n "${TRELLO_API_KEY:-}" ] && [ -n "${TRELLO_TOKEN:-}" ] || { note "Trello : clés absentes de l'environnement (--setenv=TRELLO_*), carte $1 non déplacée"; return 0; }
  actuelle=$(curl -s "https://api.trello.com/1/cards/$id?key=$TRELLO_API_KEY&token=$TRELLO_TOKEN&fields=idList" | sed -n 's/.*"idList":"\([0-9a-f]*\)".*/\1/p')
  [ "$actuelle" = "$2" ] || [ "$actuelle" = "$LISTE_FINIE" ] && return 0
  curl -s -o /dev/null -w "%{http_code}" -X PUT "https://api.trello.com/1/cards/$id?key=$TRELLO_API_KEY&token=$TRELLO_TOKEN&idList=$2&pos=bottom" \
    | grep -q 200 && note "Trello : carte $1 ($id) en $3" || note "Trello : échec du déplacement de la carte $1 en $3"
}
trello_wip() { trello_vers "$1" "$LISTE_WIP" "Work in progress"; }
# Cartes d'une étape poussée : en Waiting for review si leur travail est déjà dans une PR ouverte vers $REL.
# Une branche -vB n'a pas de PR : ses cartes attendent le balayage d'après la FUSION.
trello_attente() {  # <cartes> <repo> <branche>
  local dir=$REPO_BACK n c
  case $3 in *-v[B-Z]) return 0 ;; esac
  [ "$1" = - ] && return 0  # étape de FIN sans carte (fusion, suites complètes) : rien à déplacer
  [ "$2" = front ] && dir=$REPO_FRONT
  n=$(cd "$dir" && gh pr list --head "$3" --base "$REL" --state open --json number --jq '.[0].number // empty' 2>/dev/null)
  [ -n "$n" ] || return 0
  for c in ${1//,/ }; do [ "$c" = "-" ] || trello_vers "$c" "$LISTE_ATTENTE" "Waiting for review"; done
}
# Balayage après la FIN : les cartes de toutes les étapes A, B et FIN réussies, -vB comprises (fusionnées), passent en
# Waiting for review si l'appli a sa PR de lot. Rattrape aussi une étape poussée avant l'ouverture de la PR. Une carte
# placée en FIN (un renommage général fait après la fusion, par exemple) restait sinon en Work in progress.
balayer_cartes() {
  local nom phase repo cartes br reste avec
  avec=$(prs_du_lot | awk '{print $4}')
  grep -vE '^[[:space:]]*(#|$)' "$ETAPES" | while read -r nom phase repo cartes br reste; do
    case $phase in A|B|C|FIN) ;; *) continue ;; esac
    [ "$cartes" != "-" ] || continue
    grep -qx "$nom" "$LOGS/$PREFIX-ok.txt" 2>/dev/null || continue
    grep -qx "$(workflow_de "$repo")" <<<"$avec" || continue
    for c in ${cartes//,/ }; do trello_vers "$c" "$LISTE_ATTENTE" "Waiting for review"; done
  done
}

# Les voies partagent le .git de chaque dépôt : deux `git fetch` ou `worktree add` au même instant butent sur les
# verrous de références. Les gestes git du lanceur passent donc un par un, par dépôt.
git_seul() {  # <repo> <commande…>
  local repo=$1 rc; shift
  (
    exec 8>"$LOGS/$PREFIX-git-$repo.lock"
    flock 8
    "$@"
  ); rc=$?
  return $rc
}

# Répertoire de travail d'une étape : quand une voie d'avant (A pour B, A ou B pour C) a aussi des étapes sur ce
# dépôt, la voie travaille dans son propre worktree pour ne jamais partager l'arbre d'une autre.
dossier() {
  local repo=$1 phase=$2 base_dir
  base_dir=$REPO_BACK; [ "$repo" = front ] && base_dir=$REPO_FRONT
  if { [ "$phase" = B ] || [ "$phase" = C ]; } && grep -vE '^[[:space:]]*(#|$)' "$ETAPES" \
       | awk -v r="$repo" -v p="$phase" '$2 ~ /^[ABC]$/ && $2 < p && $3 == r {f = 1} END {exit !f}'; then
    local wt="$base_dir-wt-$PREFIX-v$phase"
    if [ ! -d "$wt" ]; then
      git_seul "$repo" git -C "$base_dir" fetch -q origin
      git_seul "$repo" git -C "$base_dir" worktree add -q --detach "$wt" "refs/remotes/origin/$REL" >>"$CHAIN" 2>&1 || return 1
      note "worktree $wt créé" >/dev/null
      if [ "$repo" = back ]; then (cd "$wt" && bash -c "$INSTALL_BACK" >>"$CHAIN" 2>&1); else (cd "$wt" && bash -c "$INSTALL_FRONT" >>"$CHAIN" 2>&1); fi
    fi
    echo "$wt"
  else
    echo "$base_dir"
  fi
}

preparer() {
  local dir=$1 nom=$2 br=$3 base=$4
  cd "$dir" || return 1
  if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    git stash push -q -m "$PREFIX-avant-$nom" && note "working tree sale stashé avant $nom ($dir)"
  fi
  git fetch -q origin || return 1
  if git ls-remote --exit-code --heads origin "$br" >/dev/null 2>&1; then
    if git show-ref -q --verify "refs/heads/$br"; then
      git checkout -q "$br" || return 1
      if ! git merge -q --ff-only "refs/remotes/origin/$br" 2>/dev/null; then
        git branch -f "backup/$PREFIX-$nom-$(date +%H%M)" HEAD
        git reset -q --hard "refs/remotes/origin/$br"
        note "branche locale divergente avant $nom : sauvegardée en backup/$PREFIX-$nom-*, remise sur origin"
      fi
    else
      git checkout -q -b "$br" "refs/remotes/origin/$br" || return 1
    fi
  else
    local ref="refs/remotes/origin/$base"
    git show-ref -q --verify "$ref" || ref="refs/remotes/origin/$REL"
    git checkout -q -B "$br" "$ref" || return 1
    note "branche $br créée localement depuis ${ref#refs/remotes/} ($dir)"
  fi
}

# Fin de lot jouée en script ? (MECA vide ou absent : comme avant, la passe FIN lance elle-même la suite complète.)
meca_active() { [ -n "$MECA" ] && [ -x "$MECA" ]; }
# Une étape FIN sans carte (la fin de l'application) vient-elle après l'étape <nom> pour ce dépôt ?
fin_appli_suit() {  # <repo> <nom>
  grep -vE '^[[:space:]]*(#|$)' "$ETAPES" \
    | awk -v r="$1" -v n="$2" '$1 == n {vu = 1; next} vu && $2 == "FIN" && $3 == r && $4 == "-" && $1 !~ /^FUSION/ {f = 1} END {exit !f}'
}
nb_voies() { grep -vE '^[[:space:]]*(#|$)' "$ETAPES" | awk '$2 ~ /^[ABC]$/ {print $2}' | sort -u | wc -l; }

# Tête de la branche du lot avant ce lancement si le lot est une reprise, vide sinon.
depart_de() {  # <repo>
  local v=$REPRISE_DEPUIS_BACK
  [ "$1" = front ] && v=$REPRISE_DEPUIS_FRONT
  [ -n "$v" ] || v=$(cat "$LOGS/$PREFIX-depart-$1" 2>/dev/null)
  [ "$v" = - ] && v=
  echo "$v"
}
# Le cycle de cette version a-t-il déjà reçu un verdict À REPRENDRE ? (Sans cycle : non, la reprise se déclare.)
cycle_en_reprise() {
  local f=$CYCLES/$VERSION/etat.json
  [ -f "$f" ] || return 1
  python3 -I -c 'import json, sys
e = json.load(open(sys.argv[1]))
sys.exit(0 if e.get("aller_retours", 0) >= 1 or e.get("etape") == "correction" else 1)' "$f" 2>/dev/null
}
# Au premier lancement d'un PREFIX, si le cycle est en reprise : la tête de la branche du lot, celle que la revue a
# vue, est notée (une relance du même PREFIX ne la réécrit pas). Un premier lot relit toujours tout son diff.
noter_departs() {
  local repo br dir sha f
  grep -vE '^[[:space:]]*(#|$)' "$ETAPES" | awk '$2 ~ /^(A|B|C|FIN)$/ {print $3, $5}' | sort -u \
    | while read -r repo br; do
        case $br in *-v[B-Z]) continue ;; esac
        f=$LOGS/$PREFIX-depart-$repo
        [ -s "$f" ] && continue
        dir=$REPO_BACK; [ "$repo" = front ] && dir=$REPO_FRONT
        sha=""
        cycle_en_reprise && sha=$(git -C "$dir" ls-remote --heads origin "$br" 2>/dev/null | head -n 1 | cut -f1)
        echo "${sha:--}" >"$f"
      done
  for repo in back front; do
    sha=$(depart_de "$repo")
    [ -n "$sha" ] && note "reprise ($repo) : tête d'avant ${sha:0:9}, la relecture de fin se limite au diff depuis cette tête (REPRISE_DEPUIS_${repo^^}=- dans lot.conf pour relire tout le lot)"
  done
  return 0
}

# Relecture demandée à la passe de fin : le lot entier la première fois, le diff de la reprise ensuite (relire tout
# le lot pour corriger quelques cartes coûte cher et disperse la relecture).
relecture() {  # <repo>
  local depart; depart=$(depart_de "$1")
  if [ -n "$depart" ]; then cat <<EOF
Ce lot est une reprise de correction : la tête d'avant la reprise est \`${depart:0:12}\`. Avant ta dernière poussée,
relis le diff de la reprise, et lui seul (\`git diff $depart..HEAD\`), avec la grille de revue, \`$GRILLE\`,
celle qu'utilise $NOM_REV, section « Corriger la famille, pas le cas » : pour chaque point corrigé, la table des
variantes voisines et son test paramétré existent, les appelants des fonctions modifiées sont vérifiés, et une seule
question guide la relecture : « qu'est-ce que cette correction casse, oublie ou laisse passer ? ». Ne relis pas le
reste du lot : les cartes que la reprise ne touche pas ont déjà été relues, et tu ne sors de ce diff que pour suivre
un appelant ou une variante de la même famille. Corrige ce que tu trouves.
EOF
  else cat <<EOF
Avant ta dernière poussée, relis le diff complet du lot sur cette appli (\`git diff origin/$REL...HEAD\`) avec la
grille de revue, \`$GRILLE\`, celle qu'utilise $NOM_REV : chaque carte conforme à son texte et aux arbitrages, un test qui
échoue sans chaque correction et le test du cas voisin, les appelants vérifiés, rien hors du périmètre. Corrige ce que
tu trouves : chaque point que $NOM_REV relèvera coûte un aller-retour complet.
EOF
  fi
}

# Cadre ajouté à chaque prompt : il prime sur common-*.md pour les tests et le parallélisme.
# <mode> = PRE | VOIE (une carte : voies A, B, C, carte ou fusion placée en FIN avant la fin de l'application) |
#          FIN (fin d'application sans script : la passe lance la suite) | RELECTURE | CORRECTION (fin en script)
cadre() {
  local phase=$1 repo=$2 workers=$3 verif="" regles
  echo; echo "## Cadre d'exécution de cette passe (prime sur toute consigne de test ou de CI contraire plus haut)"; echo
  regles=$(cat "$REGLES_ARBITRAGE" 2>/dev/null || echo "(fichier des règles absent : $REGLES_ARBITRAGE)")
  if [ "$phase" = FIN ] && [ -n "$VERIF_FIN" ]; then
    verif="Avant ta dernière poussée, lance \`$VERIF_FIN \"\$PWD\" origin/$REL\`. Sortie 1 : corrige tout ce qu'il liste, puis
relance-le. Sortie 2 : il n'a pas pu tourner, note-le et continue.
"
  elif [ "$phase" != FIN ] && [ -n "$VERIF" ]; then
    verif="Avant chaque poussée, lance \`$VERIF \"\$PWD\" origin/$REL\`. Sortie 1 : corrige tout ce qu'il liste, puis
relance-le. Sortie 2 : il n'a pas pu tourner, note-le dans la passation et continue.
"
  fi
  case $phase in
    PRE) cat <<EOF
Passe d'étude et de mesure, en tête de lot : aucune implémentation de carte ici. Mesure ce qui doit l'être
(seuils, taux de rejet, écarts de modèles, volumétrie…) sur des données réelles, et écris chaque question
d'arbitrage dans \`$LOT/questions-arbitrage.md\` (numérotée, options chiffrées, recommandation). $NOM_DEV les
tranche lui-même avec les règles d'arbitrage du projet, dans leur ordre de priorité :

$regles

Marque \`[BLOQUANTE]\` une question que ces règles ne suffisent pas à trancher (choix de produit, dépense, accès ou
action de $NOM_HUMAIN) : le lot s'arrêtera pour elle. Mieux vaut une question de trop maintenant qu'une reprise de 10 h
après la passe FIN.
EOF
      ;;
    FIN) cat <<EOF
Passe de fin : c'est ici, et seulement ici, que tourne la suite complète de chaque application touchée, comme
la CI ($SUITE_FIN), avec au plus $workers workers. Corrige tout ce qui rougit avant de conclure.

${verif}Vérifie aussi que la PR n'est pas en conflit avec \`origin/$REL\` (\`gh pr view --json mergeable\`) : en conflit, aucune
CI ne part en fin de lot. Mets alors ta branche à jour avec \`origin/$REL\` et rejoue les tests touchés avant de pousser.

$(relecture "$repo")

CI : pousse, puis termine. Ne la déclenche pas, ne l'attends pas, ne relance aucun run, même si l'étape le demande
plus haut : la PR porte l'étiquette \`$PAUSE\` jusqu'à la fin du lot, puis le lanceur lance la CI des PR sur leurs
têtes finales, attend les verdicts et les remet à l'agent.
EOF
      ;;
    RELECTURE) cat <<EOF
Passe de fin, relecture. La suite complète, le lint, le typage, le build, les e2e complets et les autres contrôles
de la liste de fin (vérification avant poussée, audit des dépendances) ne se lancent PAS dans cette passe : le
lanceur les joue lui-même, en script, juste après elle, sur la tête que tu auras poussée, et ne rappelle une passe
que s'il y a du rouge, avec son rapport. Si l'étape te les demande plus haut, ne les lance pas : c'est fait après toi.
Dans cette passe : uniquement les tests ciblés de ce que tu modifies (fichiers de test des modules touchés, et ceux
qui les importent), au plus $workers workers (\`-n $workers\` pour pytest, \`--maxWorkers=$workers\` pour vitest).

$(relecture "$repo")

Vérifie aussi que la PR n'est pas en conflit avec \`origin/$REL\` (\`gh pr view --json mergeable\`) : en conflit, aucune
CI ne part en fin de lot. Mets alors ta branche à jour avec \`origin/$REL\` et rejoue les tests touchés avant de pousser.

CI : pousse, puis termine. Ne la déclenche pas, ne l'attends pas, ne relance aucun run, même si l'étape le demande
plus haut : la PR porte l'étiquette \`$PAUSE\` jusqu'à la fin du lot, puis le lanceur lance la CI des PR sur leurs
têtes finales, attend les verdicts et les remet à l'agent.
EOF
      ;;
    CORRECTION) cat <<EOF
Passe de fin, correction. Le lanceur vient de jouer en script, sans Claude, la partie mécanique de la fin de lot
(suite complète, lint, typage, build, e2e, contrôles de la liste de fin) : son rapport est en tête de ce prompt, avec le
journal de chaque commande rouge. Corrige chaque rouge à la racine, sans affaiblir un test ni une règle. Ne rejoue
que les commandes rouges, telles que le rapport les écrit, et les tests ciblés de ce que tu touches, au plus
$workers workers : le lanceur rejoue la partie mécanique après ta poussée, sauf les commandes longues déjà vertes
(passage ${FIN_TOUR:-1} sur $MAX_TOURS_FIN, le dernier rouge arrête le lot). Ne touche donc pas, sans nécessité, à ce que
couvrent les commandes vertes du rapport : seule la CI de fin de lot les rejouera. Un rouge qui ne vient pas du code (machine chargée, test instable, service injoignable) :
rejoue la commande seule une fois ; si elle passe, ne change rien et dis-le en une ligne dans ta conclusion.
Ne relis pas le lot : la relecture est faite, tu ne touches qu'à ce que le rapport montre rouge.

CI : pousse, puis termine. Ne la déclenche pas, ne l'attends pas, ne relance aucun run : la PR porte l'étiquette
\`$PAUSE\` jusqu'à la fin du lot, puis le lanceur lance la CI des PR sur leurs têtes finales.
EOF
      ;;
    *) cat <<EOF
Tests pendant cette passe : uniquement les tests ciblés de ce que tu touches (fichiers de test des modules
modifiés, et ceux qui les importent) plus le lint et le typage, jamais la suite complète : elle tourne une seule
fois par application, en fin de lot. Au plus $workers workers (\`-n $workers\` pour pytest, \`--maxWorkers=$workers\`
pour vitest). Une autre voie peut travailler en même temps sur la machine.${E2E_PORT:+ Si tu lances des e2e ciblés, avec \`E2E_PORT=$E2E_PORT\`.}

${verif}CI : ne la déclenche pas et ne l'attends pas. Ni fermeture-réouverture de la PR, ni \`gh run rerun\`, ni attente d'un
run après ta poussée : la PR porte l'étiquette \`$PAUSE\` jusqu'à la fin du lot, et le lanceur lance la CI une seule
fois, après la dernière passe.

Cette passe ne porte qu'une carte. Termine-la entièrement (poussée, tests ciblés verts), puis écris avant de
conclure une note de passation courte (30 lignes au plus) dans \`$PASSATION\`, hors du dépôt : ce qui est fait,
les décisions prises, les pièges rencontrés, les tests ciblés joués. La passe suivante de ta voie la recevra.
EOF
      ;;
  esac
}

claude_passe() {
  local dir=$1 prompt=$2 log=$3 essai=$4
  (
    cd "$dir" || exit 1
    echo "=== début $(date -Is) essai $essai, branche $(git rev-parse --abbrev-ref HEAD) ==="
    if [ "$essai" -eq 1 ]; then
      $CLAUDE --permission-mode bypassPermissions --print <"$prompt"
    else
      $CLAUDE --permission-mode bypassPermissions --print <<<"$(cat "$prompt"; echo; echo "Reprise : une passe précédente sur cette même étape s'est interrompue (essai $((essai - 1))). Relis la branche et la PR, reprends là où elle s'est arrêtée, ne refais pas ce qui est déjà poussé.")"
    fi
    rc=$?
    echo; echo "=== fin $(date -Is) rc=$rc ==="
    exit $rc
  ) >>"$log" 2>&1
}

etape() {
  local nom=$1 phase=$2 repo=$3 carte=$4 br=$5 base=$6 opt=${7:-}
  local dir log=$LOGS/$PREFIX-$nom.log prompt=$LOGS/$PREFIX-$nom.prompt.md workers=$WORKERS_FIN common mode=$phase
  dir=$(dossier "$repo" "$phase") || { note "ÉCHEC worktree $nom"; return 1; }
  if [ "$MODE" = impl ] && [ "$phase" != FIN ]; then
    workers=$WORKERS_VOIE
    [ "$(nb_voies)" -ge 3 ] && [ "$workers" -gt "$WORKERS_3VOIES" ] && workers=$WORKERS_3VOIES
  fi
  case $phase in
    A|B|C) mode=VOIE ;;
    FIN) if [ -n "${FIN_MODE:-}" ]; then mode=$FIN_MODE
         elif meca_active && fin_appli_suit "$repo" "$nom"; then mode=VOIE; fi ;;
  esac
  common=$LOT/common-$repo.md
  [ "${nom#FIN}" != "$nom" ] && common="$LOT/common-back.md $LOT/common-front.md"
  [ -f "$LOT/common-${br##*-}.md" ] && common="$common $LOT/common-${br##*-}.md"
  { if [ -n "${FIN_RAPPORT:-}" ]; then cat "$FIN_RAPPORT"; else cat "$LOT/step-$nom.md"; fi; echo
    for c in ${carte//,/ }; do [ "$c" = "-" ] || cat "$LOT/card-$c.md"; done
    [ -f "$LOT/arbitrages.md" ] && cat "$LOT/arbitrages.md"; echo
    for f in $common; do [ -f "$f" ] && cat "$f"; done
    # une carte = une passe : le contexte de la carte précédente de la voie n'arrive que par sa note de passation
    local prec; prec=$(cat "$LOGS/$PREFIX-derniere-${VOIE:-$phase}" 2>/dev/null)
    if [ -n "$prec" ] && [ -s "$LOGS/$PREFIX-passation-$prec.md" ]; then
      echo; echo "## Note de passation de l'étape précédente de ta voie ($prec)"; echo
      cat "$LOGS/$PREFIX-passation-$prec.md"
    fi
    PASSATION=$LOGS/$PREFIX-passation-$nom.md cadre "$mode" "$repo" "$workers"; } >"$prompt"
  prendre_creneau || return 2
  for c in ${carte//,/ }; do [ "$c" = "-" ] || trello_wip "$c"; done
  local essai rc
  for essai in 1 2 3; do
    note "=== étape $nom ($phase, $repo, $br) : préparation (essai $essai)"
    if ! git_seul "$repo" preparer "$dir" "$nom" "$br" "$base" >>"$CHAIN" 2>&1; then note "ÉCHEC préparation $nom"; rendre_creneau; return 1; fi
    note "=== étape $nom : run Claude Code, créneau $CRENEAU, $workers workers (log $log)"
    local t0=$SECONDS
    claude_passe "$dir" "$prompt" "$log" "$essai"; rc=$?
    local duree=$((SECONDS - t0)) loc dist
    cd "$dir" && git_seul "$repo" git fetch -q origin
    loc=$(git rev-parse "refs/heads/$br" 2>/dev/null); dist=$(git rev-parse "refs/remotes/origin/$br" 2>/dev/null)
    if [ "$rc" -eq 0 ] && [ -n "$dist" ] && [ "$loc" = "$dist" ]; then
      note "OK étape $nom : $repo $br poussée en ${dist:0:7} (${duree}s)"; rendre_creneau
      echo "$nom" >"$LOGS/$PREFIX-derniere-${VOIE:-$phase}"
      echo "$nom" >>"$LOGS/$PREFIX-ok.txt"
      case $phase in A|B|C|FIN) trello_attente "$carte" "$repo" "$br" ;; esac
      case $phase in A|B|C) [ -s "$LOGS/$PREFIX-passation-$nom.md" ] || note "$nom : pas de note de passation écrite" ;; esac
      return 0
    fi
    if [ "$rc" -eq 0 ] && { [ "$opt" = opt ] || [ "$phase" = PRE ]; }; then
      note "OK étape $nom : rien à pousser sur $repo (${duree}s)"; rendre_creneau
      echo "$nom" >>"$LOGS/$PREFIX-ok.txt"; return 0
    fi
    note "ÉCHEC étape $nom essai $essai : rc=$rc local=${loc:0:7} origin=${dist:0:7} durée=${duree}s"
    [ "$duree" -lt 600 ] && [ "$essai" -lt 3 ] && { note "échec rapide, attente de ${ATTENTE_ECHEC_S} s avant reprise"; sleep "$ATTENTE_ECHEC_S"; }
  done
  rendre_creneau
  return 1
}

# Partie mécanique de la fin d'une application, jouée par $MECA sans Claude : les commandes de
# fin-mecanique-<app>.txt (suite complète, lint, typage, build, e2e, audit…), puis l'état de la PR face à la release. Le rapport va dans <rapport>.
# Retour : 0 vert, 1 rouge, 2 ni créneau ni mémoire, 3 n'a pas pu tourner (préparation, script).
mecanique() {  # <nom> <repo> <branche> <base> <rapport> <passage>
  local nom=$1 repo=$2 br=$3 base=$4 rapport=$5 tour=${6:-1} dir liste j rc n t0 allege="" fd
  dir=$(dossier "$repo" FIN) || return 3
  # une partie mécanique à la fois dans le lot : l'autre file de FIN attend ici, sans créneau pris
  exec {fd}>"$LOGS/$PREFIX-meca.lock"
  flock -n "$fd" || { note "$nom : partie mécanique en attente de celle de l'autre file"; flock "$fd"; }
  prendre_creneau || { exec {fd}>&-; return 2; }
  if ! git_seul "$repo" preparer "$dir" "$nom" "$br" "$base" >>"$CHAIN" 2>&1; then
    note "ÉCHEC préparation $nom (partie mécanique)"; rendre_creneau; exec {fd}>&-; return 3
  fi
  [ "$tour" -gt 1 ] && allege=1
  liste=$LOT/fin-mecanique-$repo.txt; [ -f "$liste" ] || liste=""
  j=$LOGS/$PREFIX-$nom-meca
  note "=== étape $nom : partie mécanique sans Claude ($repo, $br, $WORKERS_FIN workers, créneau $CRENEAU, passage $tour${allege:+, allégé : commandes longues déjà vertes non rejouées}, journaux $j)"
  t0=$SECONDS
  MECA_ALLEGE=$allege WORKERS=$WORKERS_FIN VERIF=$VERIF_FIN "$MECA" "$repo" "$dir" "origin/$REL" "$j" ${liste:+"$liste"} >"$rapport" 2>>"$CHAIN" {fd}>&-; rc=$?
  # PR en conflit avec la release : aucun run de PR ne partirait en fin de lot
  n=$(cd "$dir" && gh pr list --head "$br" --base "$REL" --state open --json number --jq '.[0].number // empty' 2>/dev/null)
  if [ "$rc" -le 1 ] && [ -n "$n" ] && [ "$(cd "$dir" && gh pr view "$n" --json mergeable --jq .mergeable 2>/dev/null)" = CONFLICTING ]; then
    { echo; echo "- ROUGE   **conflit** : la PR $n est en conflit avec \`origin/$REL\`, aucune CI ne partirait en fin de lot. Mets \`$br\` à jour avec \`origin/$REL\`, résous les conflits, rejoue les tests des fichiers touchés et pousse."; } >>"$rapport"
    rc=1
  fi
  rendre_creneau; exec {fd}>&-
  case $rc in
    0) note "OK étape $nom : partie mécanique verte sur $(git -C "$dir" rev-parse --short HEAD) ($((SECONDS - t0))s)" ;;
    1) note "étape $nom : partie mécanique ROUGE en $((SECONDS - t0))s, $(sed -n 's/^Verdict : //p' "$rapport" | head -n 1) (rapport $rapport)" ;;
    *) note "ÉCHEC étape $nom : la partie mécanique n'a pas pu tourner (rc=$rc, voir $CHAIN)"; rc=3 ;;
  esac
  return $rc
}

# Fin d'une application (étape FIN sans carte) quand la partie mécanique se joue en script : relecture par Claude si
# l'étape a son step-<nom>.md, puis le script, puis une passe de correction seulement s'il y a du rouge, et le
# script de nouveau. La relecture vient d'abord : la suite complète ne tourne ainsi qu'une fois quand tout est vert.
fin_appli() {  # <nom> FIN <repo> - <branche> <base> [opt]
  local nom=$1 repo=$3 br=$5 base=$6 tour r rapport
  if [ -f "$LOT/step-$nom.md" ]; then
    FIN_MODE=RELECTURE etape "$@" || return $?
  else
    note "étape $nom : pas de step-$nom.md, donc pas de passe de relecture ; partie mécanique seule"
  fi
  for ((tour = 1; tour <= MAX_TOURS_FIN; tour++)); do
    rapport=$LOGS/$PREFIX-$nom-meca-$tour.md
    mecanique "$nom" "$repo" "$br" "$base" "$rapport" "$tour"; r=$?
    case $r in 0) return 0 ;; 2) return 2 ;; 3) return 1 ;; esac
    [ "$tour" -lt "$MAX_TOURS_FIN" ] || break
    FIN_MODE=CORRECTION FIN_RAPPORT=$rapport FIN_TOUR=$((tour + 1)) etape "$nom-c$tour" FIN "$repo" - "$br" "$base" || return $?
  done
  note "ÉCHEC étape $nom : partie mécanique encore rouge après $MAX_TOURS_FIN passage(s), dernier rapport $rapport"
  return 1
}

# FUSION <phase FIN> <repo> - <branche cible (celle du lot)> <branche source (-vB ou -vC)>
fusion() {
  local nom=$1 repo=$3 cible=$5 source=$6 dir
  dir=$(dossier "$repo" A)
  git_seul "$repo" preparer "$dir" "$nom" "$cible" "$REL" >>"$CHAIN" 2>&1 || { note "ÉCHEC préparation $nom"; return 1; }
  git -C "$dir" ls-remote --exit-code --heads origin "$source" >/dev/null 2>&1 || { note "OK $nom : $source absente, rien à fusionner"; return 0; }
  if git -C "$dir" merge -q --no-ff --no-edit "refs/remotes/origin/$source" >>"$CHAIN" 2>&1; then
    git -C "$dir" push -q origin "$cible" >>"$CHAIN" 2>&1 && { note "OK $nom : $source fusionnée dans $cible sans conflit"; return 0; }
    note "ÉCHEC $nom : push de $cible refusé"; return 1
  fi
  local conflits; conflits=$(git -C "$dir" diff --name-only --diff-filter=U | tr '\n' ' ')
  git -C "$dir" merge --abort
  note "$nom : conflits sur $conflits, résolution confiée à Claude"
  [ -f "$LOT/step-$nom.md" ] || cat >"$LOT/step-$nom.md" <<EOF
# $nom : fusion de deux voies

Fusionne \`origin/$source\` (l'autre voie) dans \`$cible\` (la branche du lot) : \`git merge --no-ff origin/$source\`.
Fichiers en conflit au premier essai : $conflits
Résous chaque conflit en gardant le comportement voulu par les DEUX voies (relis leurs commits et leurs cartes),
jamais en écrasant l'une par l'autre. Lance les tests ciblés des fichiers en conflit, commite la fusion et pousse
\`$cible\`. N'ouvre pas de PR pour \`$source\` : son contenu arrive par cette fusion.
EOF
  etape "$nom" FIN "$repo" - "$cible" "$REL"
}

prochaine() {  # <phase> [<repo> : la file de ce dépôt seulement]
  local ph=$1 rp=${2:-}
  grep -vE '^[[:space:]]*(#|$)' "$ETAPES" | while read -r nom phase repo reste; do
    [ "$phase" = "$ph" ] || continue
    [ -z "$rp" ] || [ "$repo" = "$rp" ] || continue
    grep -qx "$nom" "$FAITES" 2>/dev/null || { echo "$nom $phase $repo $reste"; break; }
  done
}

# Déroule toutes les étapes d'une phase, dans l'ordre d'etapes.txt (relu à chaque étape, modifiable à chaud).
phase() {  # <phase> [<repo>]
  local ph=$1 rp=${2:-} ok=0 ko="" ligne r
  VOIE=$ph${rp:+-$rp}
  while :; do
    ligne=$(prochaine "$ph" "$rp")
    [ -z "$ligne" ] && break
    set -- $ligne
    if [ "${1#FUSION}" != "$1" ]; then fusion "$@"
    elif [ "$ph" = FIN ] && [ "$4" = - ] && meca_active; then fin_appli "$@"
    else etape "$@"; fi
    r=$?
    # une passe qui vient d'ouvrir la PR du lot a déclenché sa CI : étiquette posée, run annulé
    [ "$MODE" = impl ] && ci_pause
    # r=2 : l'étape n'a pas tourné (ni créneau ni mémoire) ; la noter faite la ferait sauter à la relance.
    [ "$r" -eq 2 ] || echo "$1" >>"$FAITES"
    case $r in
      0) ok=$((ok + 1)) ;;
      2) note "##### phase $VOIE arrêtée à $1 (créneau ou mémoire)"; echo "$ok:$ko $1" >"$LOGS/$PREFIX-bilan-$VOIE"; return 2 ;;
      *) ko="$ko $1"; note "##### étape $1 en échec, la phase continue" ;;
    esac
  done
  note "##### phase $VOIE terminée : $ok étapes OK, en échec :${ko:- aucune}"
  echo "$ok:$ko" >"$LOGS/$PREFIX-bilan-$VOIE"
  [ -z "$ko" ]
}

note "##### $PREFIX $MODE lancée (lot $LOT, $MAX_VOIES créneaux Claude)"
case $MODE in
  pre)
    phase PRE; r=$?
    if [ -s "$LOT/questions-arbitrage.md" ]; then
      note "##### ARBITRAGES EN ATTENTE : $LOT/questions-arbitrage.md, à trancher (« $TITRE_DECISIONS ») ou à poser à $NOM_HUMAIN si une question est [BLOQUANTE], avant 'impl'"
    fi
    exit $r
    ;;
  impl)
    # l'agent tranche les arbitrages avec les règles du projet (« $TITRE_DECISIONS ») ; une question [BLOQUANTE]
    # attend la réponse de l'humain (« $TITRE_REPONSES »)
    if [ -s "$LOT/questions-arbitrage.md" ] && ! grep -qF -e "$TITRE_DECISIONS" -e "$TITRE_REPONSES" "$LOT/arbitrages.md" 2>/dev/null; then
      note "ABANDON : questions-arbitrage.md sans « $TITRE_DECISIONS » ni « $TITRE_REPONSES » dans arbitrages.md"; exit 1
    fi
    if grep -q "\[BLOQUANTE\]" "$LOT/questions-arbitrage.md" 2>/dev/null && ! grep -qF "$TITRE_REPONSES" "$LOT/arbitrages.md" 2>/dev/null; then
      note "ABANDON : question [BLOQUANTE] sans « $TITRE_REPONSES » dans arbitrages.md (cycle-lot arret)"; exit 1
    fi
    # une carte = une passe : refuser une étape de voie (A, B ou C) qui en porte plusieurs
    multi=$(grep -vE '^[[:space:]]*(#|$)' "$ETAPES" | awk '$2 ~ /^[ABC]$/ && $4 ~ /,/ {print $1 "(" $4 ")"}' | tr '\n' ' ')
    [ -n "$multi" ] && { note "ABANDON : étapes à plusieurs cartes, une carte = une passe : $multi"; exit 1; }
    # chaque voie a son arbre de travail sur un dépôt, donc sa branche : feat/<ver>-lot, puis -vB et -vC
    memes=$(grep -vE '^[[:space:]]*(#|$)' "$ETAPES" | awk '$2 ~ /^[ABC]$/ {print $3, $5, $2}' | sort -u \
            | awk '{k = $1 " " $2; n[k]++; v[k] = v[k] $3} END {for (k in n) if (n[k] > 1) printf "%s (voies %s) ", k, v[k]}')
    [ -n "$memes" ] && { note "ABANDON : deux voies sur la même branche du même dépôt, chacune a son worktree donc sa branche (-vB, -vC, fusionnée par une étape FUSION en FIN) : $memes"; exit 1; }
    # CI pendant un lot : aucun prompt du lot ne déclenche, n'attend ni ne relance la CI. Une consigne de CI recopiée
    # d'un ancien prompt ferait attendre une passe sur des runs en pause.
    vieux=$(grep -nHE 'gh pr (close|reopen)|close/reopen|gh run rerun|suis la CI' "$LOT"/common-*.md "$LOT"/step-*.md 2>/dev/null | head -n 5)
    [ -n "$vieux" ] && { note "ABANDON : consignes de CI dans les prompts du lot (la CI ne tourne qu'en fin de lot, voir README) : $(echo "$vieux" | sed "s#$LOT/##" | cut -c1-140 | tr '\n' ' ')"; exit 1; }
    rm -f "$LOT/.ci-fin"  # laissée par un lanceur mort pendant son étape CI
    noter_departs
    for c in $(grep -vE '^[[:space:]]*(#|$)' "$ETAPES" | awk '$2 ~ /^[ABC]$/ && $4 != "-" {print $4}' | tr ',' ' '); do
      trello_wip "$c"
    done
    ci_pause
    # la voie C est facultative : elle ne part que si etapes.txt lui donne des étapes au lancement
    avec_c=""; [ -n "$(prochaine C)" ] && avec_c=1
    E2E_PORT=$E2E_PORT_A phase A & pa=$!
    E2E_PORT=$E2E_PORT_B phase B & pb=$!
    [ -n "$avec_c" ] && { E2E_PORT=$E2E_PORT_C phase C & pc=$!; }
    wait $pa; ra=$?; wait $pb; rb=$?
    rvc=0; [ -n "$avec_c" ] && { wait $pc; rvc=$?; }
    VOIE=
    note "##### voies terminées : A rc=$ra, B rc=$rb${avec_c:+, C rc=$rvc}"
    if [ "$ra" -eq 2 ] || [ "$rb" -eq 2 ] || [ "$rvc" -eq 2 ]; then note "##### lot arrêté avant FIN (créneau ou mémoire)"; ci_reprise; exit 1; fi
    fin_repos=$(grep -vE '^[[:space:]]*(#|$)' "$ETAPES" | awk '$2 == "FIN" {print $3}' | sort -u | tr '\n' ' ')
    if [ "$FIN_PARALLELE" = 1 ] && [ "$(wc -w <<<"$fin_repos")" -ge 2 ]; then
      note "##### phase FIN en $(wc -w <<<"$fin_repos") files parallèles : $fin_repos(parties mécaniques une à la fois)"
      pids=()
      for rp in $fin_repos; do E2E_PORT=3123 phase FIN "$rp" & pids+=($!); done
      rf=0
      for p in "${pids[@]}"; do wait "$p"; r=$?; [ "$r" -eq 0 ] || { [ "$rf" -eq 2 ] || rf=$r; }; done
      VOIE=
      note "##### phase FIN terminée (files parallèles), rc=$rf"
    else
      phase FIN; rf=$?
    fi
    VOIE=
    balayer_cartes
    if [ "$ra" -eq 0 ] && [ "$rb" -eq 0 ] && [ "$rvc" -eq 0 ] && [ "$rf" -eq 0 ]; then
      ci_fin; rc=$?
    else
      ci_reprise; rc=1
    fi
    note "##### $PREFIX terminé : A rc=$ra, B rc=$rb${avec_c:+, C rc=$rvc}, FIN rc=$rf, CI rc=$rc"
    [ "$ra" -eq 0 ] && [ "$rb" -eq 0 ] && [ "$rvc" -eq 0 ] && [ "$rf" -eq 0 ] && [ "$rc" -eq 0 ]
    ;;
  *) echo "mode inconnu : $MODE" >&2; exit 64 ;;
esac
