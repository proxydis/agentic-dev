# agentic-dev

*[English version](README.md)*

Deux outils pour faire développer, relire et livrer un lot de cartes par deux agents IA, un développeur et un
relecteur, de « lance le lot 1.0.0 » jusqu'à la validation en production. L'humain lance le lot et ne revient que
pour les décisions qu'il est seul à pouvoir prendre.

- **`run-lot.sh`** : le lanceur du développement. Il découpe le lot en passes [Claude Code](https://docs.claude.com/en/docs/claude-code)
  non interactives, une carte par passe, sur deux ou trois voies parallèles. Il fait tourner la suite complète une
  seule fois en fin de lot, en script et sans Claude, puis lance la CI des pull requests du lot.
- **`cycle-lot`** : le cycle complet, de la revue à la mise en production. Une machine à états par lot, que les agents
  font avancer par des commandes, et un relais systemd qui les réveille à leur tour et tient seul toutes les attentes
  (CI, déploiements).

Les deux outils ont été écrits pour des agents [OpenClaw](https://docs.openclaw.ai) qui travaillent dans Slack, sur
deux dépôts GitHub (back et front), avec un tableau Trello. Tout ce qui est propre à une installation passe par des
fichiers de configuration non versionnés.

## Le cycle d'un lot

| # | Étape | Qui | Ce qui se passe |
|---|---|---|---|
| 1 | Démarrage | dev | `cycle-lot debut` : cartes du lot en Work in progress, branches `release/<version>` tirées de `develop` |
| 2 | Développement | dev | `run-lot.sh pre`, puis `impl` : branches `feat/…` tirées de la release, pull requests vers la release |
| 3 | Arbitrages | dev | Le dev tranche lui-même avec les règles du projet (`regles-arbitrage.md`) et note ses décisions |
| 4 | Arbitrage bloquant | dev → humain | Une question que les règles ne tranchent pas arrête le cycle (`cycle-lot arret`) |
| 5 | CI de fin de lot | `run-lot.sh` | Tests unitaires et e2e, qualité et sécurité, une fois, sur les têtes finales des PR |
| 6 | CI rouge | dev | Le dev corrige avant de demander la revue : `cycle-lot passe` refuse une CI qui n'est pas verte |
| 7 | Revue | relecteur | Relecture, tests, parcours Playwright sur la version déployée du lot ; verdict À MERGER ou À REPRENDRE. La 1re revue exige les preuves en réel du dev (`passe --reel`), et chaque revue suivante les exige de nouveau sur la tête de la reprise. Une revue de correction ne relit que le diff depuis la tête revue |
| 8 | Correction | dev | Revues 1 et 2 : tous les points, bloquants et non bloquants. À partir de la 3e revue : les bloquants seuls, chaque non bloquant devient une carte du lot suivant. Le dev corrige la famille de chaque défaut, pas le seul cas, et une passe distincte relit le diff de la reprise (`passe --contre-relecture`) |
| 9 | 7 ↔ 8 | | Automatique jusqu'à À MERGER ; arrêt au 5e À REPRENDRE |
| 10 | Merge du lot | relecteur, relais | Le verdict À MERGER merge aussitôt chaque PR dans la release (squash, back d'abord) ; le relais pose le commit de release (CHANGELOG, version) |
| 10b | CI de la release rouge | dev | Chaque rouge rend la main au dev avec les runs, les jobs rouges et le compteur de rouges de suite : correctif par une PR, ou relance puis `cycle-lot attendre-ci`. À partir du 3e rouge de suite, un diagnostic écrit précède toute relance |
| 11 | Livraison | relais | Release verte : le relais ouvre les 4 PR, release vers `develop` et `master`, back et front. Le dev ne s'en charge que si une intervention de l'humain ou un réglage de déploiement d'avant livraison reste ouvert |
| 12 | Revue de livraison | relais ou relecteur | CI verte et contenu limité au lot revu : le relais merge les 4 PR. Sinon le relecteur vérifie et merge |
| 13 | Mise en production | relais, puis dev | CI de `develop` et `master` (déploiement compris), puis réglages de déploiement restants (ceux qui ne se posent qu'après le déploiement), posés et prouvés par le dev, et liste des validations visuelles à faire en production |
| 13b | Diagnostic de déploiement | dev | CI de mise en production rouge (étape `diagnostic-deploiement`) : le dev diagnostique, relance, puis `cycle-lot attendre-ci --message "<diagnostic>"` rend l'attente au relais |
| 14 | Validation en production | relecteur | Playwright sur la production, une carte Trello par défaut, dans la version suivante, en Not Ready |

Trello suit le cycle : Work in progress au démarrage, Waiting for review dès qu'une passe est poussée dans la PR du
lot (étapes A, B et FIN), Under review au début de la revue, Finished ou de nouveau Work in progress au verdict. À
MERGER ne passe en Finished que les cartes en cours de lot (Work in progress, Waiting for review, Under review) ; une
carte restée en Not Ready, Standby, Blocked ou Canceled ne bouge pas et la commande la signale. Une carte validée ne
bouge plus.

**Reporter une carte.** La renommer vers sa nouvelle version (`[V1.0.1-…]`) et la remettre en Not Ready. Jusqu'au
verdict À MERGER, chaque lecture du tableau (relais, `passe`, `verdict`) aligne la liste du lot sur les titres : la
carte sort du lot (une ligne au journal, hors du total de l'avancement, « Sorties du lot » dans `cycle-lot etat`) et y
revient si on lui rend la version du lot.

**Règle de revue.** 5 aller-retours au plus (`max_aller_retours`). Aux revues 1 et 2, tout se corrige : À REPRENDRE
dès qu'il reste un point bloquant ou non bloquant. À partir de la 3e revue (`revue_report_non_bloquants`), seul un
point bloquant renvoie le lot ; le relecteur fait de chaque point non bloquant une carte du lot suivant (`cycle-lot
carte-report`) pendant la revue, et le dev ne corrige que les bloquants. `verdict` prend `--bloquants` et
`--non-bloquants` et refuse les verdicts incohérents : À REPRENDRE sans le nombre de bloquants, À MERGER avec des non
bloquants aux revues 1 et 2, À REPRENDRE sans bloquant à partir de la 3e revue, plus de non bloquants que de cartes
créées pendant la revue. Un point découvert après la 1re revue dans du code inchangé depuis est non bloquant, sauf
s'il touche la sécurité.

**Avant la revue.** Le premier passage en revue exige les preuves en réel du lot (`passe --reel <fichier>`) : pour
chaque carte qui dépend d'un service externe (modèle d'IA, base de données hébergée, e-mail, captcha, source de
données, stockage), la commande ou le parcours joué sur la préproduction et son résultat, ou `--reel aucun`. Une
intervention de l'humain sans laquelle une carte ne peut pas être vérifiée en réel se déclare avec `intervention
--ajouter … --avant revue` : la revue est refusée tant qu'elle n'est pas faite, ou que les cartes qui en dépendent ne
sont pas reportées. Après une correction, `passe` exige le rapport d'une contre-relecture (`--contre-relecture
<fichier>`) : une passe distincte qui a relu le diff de la reprise avec la grille de revue, avec pour seule question
ce que la correction casse, oublie ou laisse passer. Quand le premier passage a donné un fichier de preuves, chaque
retour en revue apporte les siennes : `--reel <fichier>` avec les preuves rejouées sur la tête de la reprise, ou
`--reel inchange --motif "<pourquoi la reprise ne touche aucun critère joué en réel>"` (20 caractères au moins). La
consigne du relecteur cite le fichier, ou le motif à vérifier contre le diff ; un motif faux est un point bloquant. La
voie courte en est exemptée.

**Jouer les preuves : `run-reel.sh`.** `run-reel.sh <dossier> [<fichier des preuves>]` lance en même temps une passe
Claude par consigne `step-REEL<suffixe>.md` du dossier (par exemple une pour les tirages réels du back, une pour les
parcours Playwright de la preview), attend qu'elles aient toutes fini, puis ajoute leurs sections, dans l'ordre des
noms, à la fin du fichier des preuves. Chaque passe n'écrit que sa section (`<dossier>/reel-sections/reel<suffixe>.md`, sous-dossier à part : le lanceur refuse de partir si une section a le chemin du fichier des preuves). Le cadre
ajouté à chaque consigne demande de lancer en même temps les tirages indépendants. Quand un cache côté serveur
resservirait un tirage identique, chaque tirage doit être rendu distinct par une donnée d'entrée sans effet sur le
critère joué (une heure de départ décalée de quelques minutes), au lieu d'attendre l'expiration du cache : trois
tirages espacés de 31 min derrière un cache de 30 min faisaient une passe d'une heure, presque toute en attente.
`REEL_PARTAGE` cite les quotas que les passes se partagent. Essai : `bash tests/essai-run-reel.sh`.

**Voie courte.** Après le merge du lot, un correctif qui ne touche que la CI, les tests ou la documentation est reconnu
à ses fichiers (`motif_voie_courte`, qui comprend les scripts que seule la CI exécute, `scripts/ci/`) : relu sur son diff, sans déploiement de preview ni contre-relecture, hors
compteur d'aller-retours. Le 3e À REPRENDRE de suite en voie courte arrête le cycle (`max_voie_courte`).

**Réglages de déploiement.** Les variables d'environnement, workflows à lancer, données à republier ou migrations
qu'une carte suppose se déclarent pendant le lot (`cycle-lot reglage <v> --ajouter …`), par le dev ou le relecteur,
avec qui doit les poser (`--qui dev`, par défaut, ou `--qui humain`). Un réglage écrit seulement dans une PR s'oublie à
la livraison, et la CI de livraison les découvre alors un par un, un rouge chacun. `ouvrir-livraison`, et le relais
quand il ouvre lui-même les PR de livraison, refusent donc tant qu'un réglage à poser avant la livraison reste à faire,
et listent chacun avec qui doit le poser ; le relais réveille alors le dev avec cette liste au lieu d'ouvrir les PR. Un
réglage qui ne peut se poser qu'après le déploiement (workflow à lancer sur `master`, données à publier sur la version
servie) se déclare `--apres-deploiement`, ou se reclasse (`reglage <v> --classer N --apres-deploiement`) : il
n'empêche pas la livraison. `ouvrir-livraison <v> --sans-reglages "<motif>"` passe outre, motif et réglages passés
outre notés au journal du lot ; le relais ne passe jamais outre. Tous les réglages, ceux d'après déploiement compris,
doivent être marqués faits avec leur preuve (`reglage <v> --fait N --preuve …`) avant le passage aux validations en
production, et le relecteur les vérifie en premier.

**Rouge de CI.** Chaque rouge de la CI de la release ou de la mise en production rend la main au dev, avec le run, les
jobs rouges et le compteur de rouges de suite (`relais.diagnostic_ci_rouges`, remis à zéro au vert de ces CI). À partir
du 3e rouge de suite, la consigne exige un diagnostic écrit dans le fil avant toute relance : la cause de chaque job
rouge, en quoi elle diffère des rouges précédents, et pourquoi la suite passera ; `attendre-ci` refuse sans lui. Un
défaut de code passe par une PR et `passe` ; un rouge sans rapport avec le code se relance (`gh run rerun <id>
--failed`, ou sans `--failed` si sa machine a disparu), puis `cycle-lot attendre-ci <v> --message "<diagnostic>"` rend
l'attente au relais, sur la CI de la release (depuis l'étape de correction) ou sur celle de la mise en production
(depuis `diagnostic-deploiement`, mêmes commits). Le relais n'arrête jamais le cycle pour un rouge : seul le dev
l'arrête (`cycle-lot arret --motif ci|deploiement`) s'il lui faut une décision ou une action de l'humain.

**Arrêts.** Le cycle s'arrête sur un arbitrage bloquant, sur une intervention nécessaire de l'humain (variable
d'environnement, jeton, compte…), au 5e verdict À REPRENDRE, au 3e À REPRENDRE de suite en voie courte, et quand une
CI de release ou de mise en production n'a aucun verdict au double du plafond de l'étape. Une CI rouge ne l'arrête
jamais. Les
arbitrages et les interventions se signalent dès le démarrage du lot, pas au milieu. À l'arrêt, le relais poste un
avis dans le fil, nomme l'agent à mentionner et l'envoie aussi à l'humain en message direct ; l'humain répond dans le
fil en mentionnant cet agent, qui relance le cycle (`cycle-lot reprise`).

## Pourquoi un relais

Deux agents qui s'attendent mutuellement finissent par s'interbloquer. Il suffit que chacun écrive un script qui attend
l'autre (« j'attends la fin des jobs du dev », « j'attends le merge du relecteur ») pour que plus rien n'avance, en
silence. Ici, aucun agent n'attend jamais :

- un agent termine son étape par une commande `cycle-lot`, qui vérifie la transition, met à jour l'état du lot et
  planifie le réveil du suivant ;
- le relais (`cycle-lot veille`, toutes les 2 min, sous systemd) exécute les réveils et tient toutes les attentes, qui
  ne dépendent que de GitHub ;
- un agent qui ne donne plus signe de vie est relancé deux fois, puis l'humain est prévenu dans le fil et en message
  direct, de nouveau toutes les 2 h (5 rappels au plus). Tout signe de vie (un job ou un tour) réarme les relances ;
- quand la CI des PR du lot est verte sur des têtes que le relecteur n'a pas vues, sans job ni tour du dev et sans
  passage de main, le relais réveille le dev au bout de 15 min au lieu de 45 (deux fois au plus par jeu de têtes) ;
- un run rouge sur du code est traité aussitôt, sans attendre les runs de l'autre dépôt. Sans aucun rouge, une attente
  au-delà du plafond de l'étape ne donne qu'un avis ; l'arrêt vient au double du plafond (des runs en file sur un
  runner unique ne sont pas une panne) ;
- un déploiement du front refusé parce que le back de la même branche n'est pas encore déployé est l'ordre normal
  d'une livraison, pas un rouge. Il se reconnaît aux messages que le workflow du front écrit (`motif_front_attend_back`)
  quand le job de déploiement est le seul rouge et que le run du back de la même branche est en cours, pas encore
  créé, ou vert. Le relais attend le back, relance une fois les jobs rouges du front `relais.attente_back_min` après le
  vert du back, et ne réveille le dev que si le front rougit de nouveau ;
- quand la machine d'un run a disparu, relancer les seuls jobs rouges les renverrait vers la même machine : le relais
  relance le run en entier (`gh run rerun <id>` sans `--failed`), une fois par run, et le note au journal.
  Déclencheurs : runner perdu en plein run (« lost communication with the server », dans le journal ou les annotations
  des jobs), machine locale qui refuse le run faute de ressources (marque écrite par le workflow,
  `motif_machine_refusee`), ou jobs en file depuis `relais.file_hors_ligne_min` sur des étiquettes dont tous les
  runners sont hors ligne (le run est annulé, puis relancé en entier au passage suivant). Jamais quand un job de
  déploiement (`jobs_deploiement`) est déjà parti : le dev est prévenu une fois à la place ;
- un job requis en file depuis `relais.file_runner_libre_min` alors qu'un runner portant ses étiquettes est en ligne
  et libre est signalé une fois au dev (run, job, étiquette attendue, runners vus), sans action automatique ni message à
  l'humain. Cette surveillance couvre les attentes du relais et la CI des PR du lot pendant le dev et la correction ;
  elle lit `actions/runs/<id>/jobs` et `actions/runners`, ce qui demande un jeton autorisé à lister les runners du dépôt
  (sinon la lecture échoue sans bruit et rien n'est signalé) ;
- avec une CI qui aiguille ses runs (un job d'aiguillage en tête de run choisit la machine, les tests peuvent être
  découpés en tranches dans une matrice, un job d'analyse statique peut porter la gate), un run qui a le job
  d'aiguillage (`ci_aiguillage.job`, même sauté) exige en plus les `ci_aiguillage.jobs_requis` de son application et
  toutes les tranches de tests présentes (`ci_aiguillage.motif_tranches`) ; le job marqueur peut les faire sauter
  légitimement. Un run sans aiguillage garde les règles ci-dessus ;
- à la première CI de release verte d'un lot, le relais compare la plus longue durée mesurée de chaque job et de
  chaque étape plafonnée de la CI à son `timeout-minutes`, et poste un avis pour celles qui dépassent 80 % (`cycle-lot
  marges` donne le même tableau à la demande). Les jobs d'une matrice (`tests-1`, `tests-2`… d'un job nommé
  `tests-${{ matrix.tranche }}`) sont mesurés face au plafond de leur job.

Le réveil passe par le RPC `agent` du gateway OpenClaw, dans la session de l'agent pour le fil Slack du lot, et sa
réponse y est postée. Il part du service systemd et non de l'exec d'un agent : le gateway refuse qu'un agent réveille
lui-même une autre session.

## Économie de jetons

Au fil d'un lot, la session d'un agent dans le fil du lot dépasse vite 100 k jetons, et chaque tour réécrit ce
contexte en cache : c'est l'essentiel du coût d'un tour, bien plus que le travail lui-même. Le relais réduit les deux.

- **Contexte neuf à chaque étape.** Avant un réveil qui ouvre une étape (revue, correction, livraison…), le relais
  remet à zéro la session de l'agent dans le fil (RPC `sessions.reset`, sur le `sessionId` lu juste avant ; le routage
  vers le fil est conservé). L'agent repart du seul contexte de démarrage, et la consigne du relais se suffit : état
  du lot, PR, rapports, commandes. Si un tour de l'agent tourne, le relais attend sa fin (30 min au plus) plutôt que de
  l'interrompre. Les relances et les réveils de fin de job gardent la session. `CYCLE_LOT_CONTEXTE_NEUF=0` désactive.
- **Gestes mécaniques sans tour d'agent.** Le verdict À MERGER merge dans la même commande. Le relais pose le commit
  de release par l'API Git de GitHub (section `[Unreleased]` du CHANGELOG basculée dans `[<version>] - date`,
  version de `package.json`), ouvre les PR de livraison, puis les merge quand leur CI est verte et que les commits de
  la release absents de `develop` sont tous des merges revus ou ce commit de release. Chaque geste est annoncé dans le
  fil ; un écart ou une CI rouge réveille le relecteur.
- **Revue de correction ciblée.** Le verdict enregistre la tête de chaque PR revue ; à la revue suivante, le relais
  donne au relecteur la plage `git diff <tête revue>..<tête actuelle>` de chaque PR, et non une nouvelle revue complète.
- **Déploiement de preview seul.** Le dispatch de la preview passe `deploiement_seul=true` (nom de l'entrée :
  `deploiement_preview.entree_deploiement_seul`) : le workflow peut sauter ses tests quand le commit a déjà un run
  vert, ce qui est le cas après `passe`. Un workflow sans cette entrée refuse le dispatch, et le relais le relance
  sans elle.
- **Contenu déjà validé.** Un workflow peut sauter ses jobs de test quand le même arbre git a déjà un run vert (PR de
  livraison, push sur `develop` ou `master`). Il fait alors tourner un job marqueur (`job_deja_valide`, par défaut
  `contenu-deja-valide`) dont le succès rend acceptables les jobs sautés listés dans `jobs_sautables`. Sans le
  marqueur, un job requis sauté reste un manque.
- **Job de revue sans suivi d'avancement.** `claude --print --disallowedTools Monitor` : les notifications d'avancement
  réveillaient l'orchestrateur de revue pour rien ; seules les fins de sous-agents et de commandes le réveillent.

## `run-lot.sh`

```
run-lot.sh <dossier-du-lot> pre    # phase PRE seule : études, mesures, questions d'arbitrage
run-lot.sh <dossier-du-lot> impl   # voies A, B (et C) en parallèle, phase FIN, puis CI des PR du lot
```

Le lanceur tourne dans une unit systemd dont le nom commence par l'identifiant de l'agent (`dev-100-impl`), avec un
plafond mémoire et un hook de fin qui réveille l'agent :

```
systemd-run --user --unit dev-100-impl --property=MemoryHigh=6G --property=MemoryMax=7G \
  --setenv=TRELLO_API_KEY=… --setenv=TRELLO_TOKEN=… \
  --property=ExecStopPost="<commande qui réveille l'agent>" \
  bash ~/agentic-dev/run-lot.sh ~/lots/1.0.0 impl
```

**Le dossier du lot** (exemple complet dans [`exemple-lot/`](exemple-lot)) :

| Fichier | Rôle |
|---|---|
| `lot.conf` | `VERSION`, `REL` (branche de release), `PREFIX` (préfixe des logs), `REPO_BACK`, `REPO_FRONT`, `LOGS`, et la table `CARTE` (numéro de carte → identifiant Trello) |
| `etapes.txt` | Une étape par ligne : `<nom> <phase> <repo> <carte\|-> <branche> <base> [opt]`, relu à chaque étape (modifiable à chaud) |
| `step-<nom>.md` | La consigne de l'étape |
| `card-<n>.md` | Le texte de la carte |
| `common-back.md`, `common-front.md` | Le cadre commun des passes de chaque application |
| `arbitrages.md` | Les décisions de l'agent et les réponses de l'humain, jointes à chaque passe |
| `fin-mecanique-<app>.txt` | Facultatif : la liste propre au lot des commandes de fin de lot, à la place de celle qui est à côté de `fin-mecanique.sh` |

**Phases.**

- **PRE** : études et mesures en tête de lot, sans implémentation. Les questions d'arbitrage vont dans
  `questions-arbitrage.md`. `impl` refuse de démarrer tant qu'elles ne sont pas tranchées dans `arbitrages.md`, ou
  qu'une question `[BLOQUANTE]` n'a pas de réponse de l'humain.
- **A, B et C** : deux ou trois voies en parallèle, une carte par passe. Une passe ne reçoit de la précédente que sa
  note de passation. Tests ciblés seulement (`WORKERS_VOIE` workers, `WORKERS_3VOIES` à trois voies). La voie C est
  facultative : une troisième file de cartes indépendantes des deux autres, qui ne part que si `etapes.txt` lui donne
  des étapes. Quand une voie touche un dépôt déjà pris par une voie d'avant, elle travaille dans son propre worktree,
  sur sa propre branche (`-vB`, `-vC`) ; `impl` refuse deux voies sur la même branche du même dépôt. Les gestes git du
  lanceur (fetch, worktree, checkout) passent un par un par dépôt, car les voies partagent le `.git` de chaque dépôt.
- **FIN** : fusion des branches `-vB` et `-vC` (étapes `FUSION…` ; Claude résout les conflits si git n'y arrive pas
  seul), cartes placées en fin de lot, puis fin de chaque application : une étape FIN sans carte.
- **Fin d'une application, en script** (quand `MECA`, par défaut `fin-mecanique.sh`, est exécutable) : d'abord une
  passe de relecture par Claude si l'étape a son `step-<nom>.md`, avec des tests ciblés seulement ; puis la partie
  mécanique, jouée par `fin-mecanique.sh` sans Claude : la liste de commandes `fin-mecanique-<app>.txt` (suite
  complète, lint, typage, build, e2e, audit…, `WORKERS_FIN` workers), plus l'état de conflit de la PR face à la
  release ; puis, seulement s'il y a du rouge, une passe de correction qui reçoit le rapport, et de nouveau le script,
  `MAX_TOURS_FIN` fois au plus. La suite complète ne tourne ainsi qu'une fois quand tout est vert, et une passe Claude
  ne garde plus pour elle des heures de commandes. Avec `MECA` vide, la passe FIN lance elle-même la suite, comme avant.
- **Garde des passes** : les passes de voie et la passe de relecture de fin tournent avec un hook `PreToolUse` de
  Claude Code, [`garde-passe.py`](garde-passe.py) (passé par `--settings`). Il refuse, avant qu'elles ne partent,
  toute suite large de tests (pytest ou vitest sans fichier, donc la suite entière, par motif, sur un dossier, ou sur
  plus de `GARDE_MAX_FICHIERS` fichiers, 25 par défaut) et toute tâche de fond (Bash `run_in_background`, Task, Agent,
  Monitor) ; Claude lit la raison et adapte sa commande. Une liste calculée (`$(cat …)`) passe. Une relecture qui
  jouait elle-même la suite complète, en arrière-plan, pouvait y passer l'essentiel de sa durée, avant que la partie
  mécanique ne la rejoue. La passe de correction (qui rejoue les commandes rouges du rapport) et une passe FIN sans
  script (`MECA` vide) n'ont pas de garde. `GARDE_PASSE=0` l'ôte. En écrivant un lot : les `step-FIN*.md` font jouer
  les mutants contre le seul fichier de test de la passe (et ceux du module muté), jamais contre une suite large ; un
  nombre de formes à vérifier se vérifie par un test paramétré, pas par la suite.
- **Passage allégé après une correction** : une commande marquée `long` dans `fin-mecanique-<app>.txt` (suite complète,
  e2e) n'est pas rejouée après une passe de correction si elle était verte au passage précédent, sur une tête ancêtre
  de la tête actuelle ; toutes les autres le sont. La CI de fin de lot la rejoue de toute façon. Un seul test unitaire
  rouge ne relance plus un quart d'heure d'e2e déjà verts.
- **Deux files en FIN** : la phase FIN suit une file par dépôt (fusions, cartes et fin du back d'un côté, fin du front
  de l'autre), dans l'ordre d'`etapes.txt` au sein de chaque file. Les passes Claude des deux files se chevauchent ;
  les parties mécaniques passent une à la fois (verrou du lot), pour ne pas jouer la suite complète d'une appli et les
  e2e de l'autre en même temps. `FIN_PARALLELE=0` dans `lot.conf` quand une étape FIN d'un dépôt doit attendre l'autre.
- **Relecture d'une reprise** : la relecture de fin d'application lit le diff complet du lot la première fois, et
  seulement le diff de la reprise (`git diff <tête d'avant>..HEAD`) quand le lot est une reprise. Dans un cycle
  `cycle-lot`, la tête d'avant est notée toute seule au premier lancement d'un `PREFIX` quand le cycle est en
  correction ; sinon, la donner dans `lot.conf` (`REPRISE_DEPUIS_BACK`, `REPRISE_DEPUIS_FRONT` ; `-` force la relecture
  du lot entier).
- **CI** : pendant le lot, une étiquette (`ci-en-pause`) fait sauter les jobs de PR et les runs déjà partis sont
  annulés. Les workflows doivent tester cette étiquette dans le `if:` de leurs jobs de PR. En fin de lot, le lanceur
  retire l'étiquette, rouvre les PR, attend les verdicts et les écrit dans son journal. Un rouge sans rapport avec le
  code (tâche Sonar tombée, coupure réseau) est relancé une fois.

**Créneaux.** Au plus `MAX_VOIES` (3) passes Claude Code à la fois sur la machine, tous lots et tous agents confondus
(verrous `flock` dans `slots/`). Chaque passe exige `SEUIL_MIO` de mémoire disponible au démarrage. Un job lourd d'un
agent (unit dont le nom correspond à `AGENTS_RE`, et qui charge vraiment la machine) occupe un créneau.

Les passes tournent avec `claude --permission-mode bypassPermissions` : réservez le lanceur à une machine ou à un
compte dédiés aux agents.

Réglages de la machine : [`run-lot.example.conf`](run-lot.example.conf), à copier en `run-lot.conf`.

**`fin-mecanique.sh`.** `fin-mecanique.sh <back|front> <dépôt> <base> <dossier des journaux> [<liste>]` joue toutes les
commandes de la liste dans l'ordre, dans le dépôt, même après un rouge (la passe de correction reçoit la liste entière
d'un coup), et écrit un rapport Markdown sur sa sortie standard ; chaque commande a son journal. Une ligne par
commande : `<nom> [apres=<nom>] [sortie2=non-joue] | <commande shell>` : `apres=` saute la commande quand celle qui est
nommée n'est pas verte (e2e après build), `sortie2=non-joue` lit la sortie 2 comme « n'a pas pu tourner » et non comme
un rouge. Les commandes reçoivent `$W` (workers), `$J` (dossier des journaux), `$T` (dossier temporaire du passage),
`$BASE`, `$E2E_PORT` et `$VERIF`. `$T` vit sous `MECA_TMP` (par défaut `~/.cache/run-lot/meca`), hors de `/tmp`
(souvent un petit tmpfs) et hors de tout dépôt git (des tests qui lancent `git ls-files` dans leur dossier temporaire
verraient le dépôt englobant) : le script refuse de tourner dans un dépôt git, et efface `$T` à la sortie. Il ne part
pas non plus quand le disque de `$T` a moins de `MECA_DISQUE_MIO` libres (sortie 2 : rien n'est joué), car un disque
plein donnerait de faux rouges. Chaque commande est plafonnée à `MECA_DELAI_S` secondes. Sortie 0 : tout est vert ;
1 : au moins un rouge ; 2 : rien n'a pu être joué. Listes d'exemple pour un back Python et un front Node :
[`fin-mecanique-back.txt`](fin-mecanique-back.txt), [`fin-mecanique-front.txt`](fin-mecanique-front.txt).

## `cycle-lot`

| Commande | Qui | Effet |
|---|---|---|
| `debut <v> --session-key <clé>` | dev, sur demande de l'humain | Crée l'état du lot, cartes en Work in progress |
| `passe <v> --vers <relecteur> --message … [--reel <f>\|aucun\|inchange --motif …] [--contre-relecture <f>]` | dev | Fin du dev ou d'une correction : CI verte exigée, preuves en réel à la 1re revue et de nouveau à chaque retour en revue (`--reel <f>`, ou `--reel inchange --motif "<motif>"`), contre-relecture après une correction, back du lot déployé sur la preview (si `deploiement_preview` est configuré), puis revue. Un correctif en voie courte se passe de preview et de contre-relecture |
| `verdict <v> --merger\|--a-reprendre --rapport <f> [--bloquants N] [--non-bloquants N] [--cartes-ok …] [--cartes-ko …]` | relecteur | Fin de revue ; `--merger` merge aussitôt les PR du lot ; verdicts incohérents refusés ; arrêt automatique au 5e À REPRENDRE |
| `merge <v> --pr back#N` | relecteur | Merge gardé : tête inchangée depuis la revue, CI verte, back avant front ; après un merge refusé au verdict, ou en revue de livraison |
| `ouvrir-livraison <v> [--sans-reglages "<motif>"]` | dev | Les 4 PR de livraison, quand le relais n'a pas pu les ouvrir ; refusé tant qu'une intervention de l'humain ou un réglage de déploiement d'avant livraison reste à faire (`--sans-reglages` passe outre le contrôle des réglages, avec un motif gardé au journal) |
| `attendre-ci <v> --message "<diagnostic>"` | dev ou relecteur | Après une relance, rend l'attente de la CI au relais : le relecteur en revue de livraison ; le dev après un rouge de la CI de la release (étape de correction) ou de la mise en production (`diagnostic-deploiement`). À partir du 3e rouge de suite, le diagnostic est exigé |
| `passe <v> --vers <relecteur> --etape validation-prod --fichier <liste>` | dev | Liste des validations visuelles en production |
| `carte-bug <v> --titre … --appli … --gravite … --description-fichier … [--version-cible <v>]` | relecteur | Carte de bug dans la version suivante (ou celle donnée, postérieure), en Not Ready |
| `carte-report <v> --titre … --appli … --gravite … --description-fichier … [--version-cible <v>]` | relecteur ou dev | Point reporté à un lot suivant, à toute étape : non bloquant à partir de la 3e revue, défaut ancien hors périmètre, reste décidé par l'humain |
| `reglage <v> [--ajouter … [--apres-deploiement] [--qui dev\|humain] \| --fait N --preuve … \| --classer N [--apres-deploiement] [--qui …]]` | dev ou relecteur | Réglages de déploiement : déclarés pendant le lot, exigés avant l'ouverture des PR de livraison (ou, déclarés `--apres-deploiement`, avant les validations en production) ; `--classer` en reclasse un ; sans option, la liste avec qui pose chacun et quand |
| `marges [--ref develop]` | tous | Plus longue durée mesurée de chaque job et de chaque étape plafonnée de la CI sur les derniers runs verts, face à son `timeout-minutes` |
| `fin <v> --rapport <f>` | relecteur | Lot livré et validé |
| `arret`, `reprise`, `intervention [--avant revue]`, `programmer`, `reveiller` | | Arrêt et reprise, interventions de l'humain (exigées avant la revue avec `--avant revue`, avant la livraison par défaut), lancement différé, réveil manuel |
| `etat [<v>] [--json]` | tous | Lecture seule |
| `veille` | relais | Le passage du timer |

L'état d'un lot vit dans `cycles/<version>/etat.json`, avec son journal `journal.log`. Le pouls du relais est dans
`cycles/.veille.json` (dernier passage, erreurs). La vue Graph d'[openclaw-task-monitor](https://github.com/proxydis/openclaw-task-monitor)
les lit pour montrer chaque lot, l'agent qui a la main, les runs que le relais attend et l'avancement du lot.

**Avancement.** À chaque passage, le relais lit le tableau Trello (une lecture, hors verrou) et écrit dans l'état de
chaque lot en cours `avancement` : cartes faites par le dev sur cartes du lot, compte par liste, liste de chaque carte
et heure de lecture. Une carte est faite dès que `run-lot.sh` l'a passée en Waiting for review (sa passe est poussée),
ou plus loin (Under review, Finished) ; renvoyée en Work in progress au verdict, elle repasse dans le reste à faire ;
annulée ou archivée, elle sort du total. Une lecture ratée garde le dernier compte et note l'erreur, sans compter
comme une erreur du relais.

**Installation.**

1. Copier [`cycle-lot.example.json`](cycle-lot.example.json) en `cycle-lot.json` et le remplir : les identifiants
   OpenClaw des deux agents et du compte qui poste les avis du relais, l'humain (nom, identifiant Slack), les dépôts
   GitHub et les jobs de CI exigés, les URL de production et de preview, les listes et étiquettes Trello. Les clés
   Trello se lisent dans l'environnement (`TRELLO_API_KEY`, `TRELLO_TOKEN`) ou dans la config d'OpenClaw. Clés
   facultatives, avec leur valeur par défaut :

   | Clé | Défaut | Rôle |
   |---|---|---|
   | `max_aller_retours` | 5 | Verdicts À REPRENDRE avant l'arrêt du cycle |
   | `revue_report_non_bloquants` | 3 | Revue à partir de laquelle les non bloquants deviennent des cartes du lot suivant |
   | `max_voie_courte` | 3 | Verdicts À REPRENDRE de suite en voie courte avant l'arrêt |
   | `motif_voie_courte` | CI, tests, docs | Expression régulière sur les chemins : un correctif d'après merge dont tous les fichiers y répondent passe en voie courte |
   | `job_deja_valide` | `contenu-deja-valide` | Job marqueur d'un workflow qui a sauté ses tests sur un contenu déjà validé |
   | `jobs_sautables` | `["quality", "e2e"]` | Jobs requis qui peuvent être sautés quand le job marqueur a réussi |
   | `deploiement_preview.entree_deploiement_seul` | `deploiement_seul` | Entrée `workflow_dispatch` d'un déploiement seul ; vide : dispatch simple |
   | `relais.ci_verte_min` | 15 | Minutes de CI verte sans passage de main avant le réveil ciblé du dev |
   | `relais.rappel_alerte_min`, `relais.nb_rappels_alerte` | 120, 5 | Rappels d'une alerte restée sans réponse, dans le fil et en message direct |
   | `relais.seuil_marge` | 0.8 | Part d'un `timeout-minutes` au-delà de laquelle une durée de CI donne un avis |
   | `relais.diagnostic_ci_rouges` | 3 | Rouges de suite de la CI de la release ou de la mise en production à partir desquels un diagnostic écrit est exigé avant toute relance |
   | `relais.attente_back_min` | 10 | Minutes après le vert du back avant de relancer le déploiement du front qui l'attendait |
   | `relais.file_hors_ligne_min` | 10 | Minutes de jobs en file sur des machines hors ligne avant d'annuler le run et de le relancer en entier |
   | `relais.file_runner_libre_min` | 15 | Minutes qu'un job requis peut rester en file alors qu'un runner qui lui convient est libre, avant de prévenir le dev |
   | `jobs_deploiement` | `["deploy"]` | Jobs qui déploient : un run où l'un d'eux est parti n'est jamais annulé ni relancé en entier ; seul job rouge admis quand le front attend le back |
   | `motif_front_attend_back` | `ATTENTE-BACK` | Expression régulière sur le journal des jobs rouges du front : déploiement refusé parce que le back de la même branche n'est pas encore déployé |
   | `motif_machine_refusee` | aucun | Expression régulière sur le journal des jobs rouges : la machine du run l'a refusé faute de ressources (relance entière) |
   | `ci_aiguillage.job` | aucun | Job d'aiguillage d'une CI qui choisit la machine de chaque run ; absent, les règles d'une CI aiguillée ne s'appliquent pas |
   | `ci_aiguillage.jobs_requis` | `{}` | Par application, jobs requis (et sautables avec le job marqueur) dans un run aiguillé |
   | `ci_aiguillage.motif_tranches` | aucun | Expression régulière des noms de tranches de tests (`^tranche-\d+$`) : toute tranche présente dans un run aiguillé est requise |
   | `slack_archives` | aucun | `https://<espace>.slack.com/archives` : lien du fil dans les messages directs ; absent, le message part sans lien (`CYCLE_LOT_SLACK_ARCHIVES` prime) |
2. Rendre la commande accessible aux agents : `ln -s ~/agentic-dev/cycle-lot ~/.local/bin/cycle-lot`.
3. Installer le relais : copier [`systemd/`](systemd) dans `~/.config/systemd/user/`, adapter le chemin, puis
   `systemctl --user enable --now cycle-lot-relais.timer`.
4. Donner aux agents leurs consignes (dans leur `AGENTS.md`) :
   - un message `[RELAIS DU CYCLE DE LOT …]` leur est adressé même sans mention, et la réponse est obligatoire ;
   - on ne passe la main que par `cycle-lot`, jamais par une mention Slack, car une mention entre agents ne lance
     aucun tour ;
   - aucun script ni unit qui attende l'autre agent ou la CI : c'est le relais qui attend ;
   - jamais d'appel direct au RPC `agent` du gateway depuis un exec ;
   - tout travail de plus de 30 min tourne dans une unit `<agent>-<prefixe>-…` (`dev-100-impl`, `relecteur-100-rev1`),
     sinon le relais croit l'agent inactif et le relance ;
   - la session du fil est remise à zéro à chaque étape : ce qui doit servir à une étape suivante s'écrit dans le
     dossier du lot ou dans un rapport, jamais seulement dans le fil ;
   - à partir du seuil de report de la règle de revue, le relecteur crée une `carte-report` par point non bloquant
     avant le verdict, et le dev ne corrige que les bloquants ;
   - après une CI rouge, le dev diagnostique, corrige par une PR ou relance, puis rend l'attente avec `cycle-lot
     attendre-ci --message "<diagnostic>"` ; à partir du 3e rouge de suite, le diagnostic écrit est d'abord posté dans
     le fil, et `cycle-lot arret` ne sert que pour une décision ou une action de l'humain ;
   - chaque retour en revue apporte ses preuves en réel (`--reel <fichier>` ou `--reel inchange --motif …`), et un
     réglage de déploiement qui ne peut se poser qu'après le déploiement se déclare `--apres-deploiement`.
5. La grille de revue commune est [`GRILLE-REVUE.md`](GRILLE-REVUE.md), et les règles d'arbitrage
   [`regles-arbitrage.example.md`](regles-arbitrage.example.md), à copier en `regles-arbitrage.md`.

## Prérequis

Linux avec systemd en mode utilisateur (cgroups v2), Python 3.11 ou plus (bibliothèque standard seule), bash, git,
la [CLI GitHub](https://cli.github.com) authentifiée, Claude Code pour `run-lot.sh`, et un gateway OpenClaw relié à
Slack pour `cycle-lot`. Les deux dépôts suivent un flux `develop` / `release/<version>` / `master`.

## Tests

```
python3 -I tests/scenario.py     # cycle-lot : cycle complet, refus, relances, arrêts, CI rouge, panne du gateway (177 vérifications)
bash tests/essai-run-lot.sh      # run-lot.sh de bout en bout, sur des dépôts git locaux : trois voies, fin de lot en
                                 # script, reprise relue sur son diff (53 vérifications, ~2 min)
python3 -I tests/essai-garde-passe.py   # garde-passe.py : ce que le garde des passes refuse et laisse passer
```

Aucun des deux n'appelle un vrai service : de faux `gh`, `openclaw`, `systemctl`, `claude` et une fausse API Trello
tiennent un monde en JSON.

## Licence

MIT, voir [LICENSE](LICENSE).
