# agentic-dev

*[English version](README.md)*

Deux outils pour faire développer, relire et livrer un lot de cartes par deux agents IA, un développeur et un
relecteur, de « lance le lot 1.0.0 » jusqu'à la validation en production. L'humain lance le lot et ne revient que
pour les décisions qu'il est seul à pouvoir prendre.

- **`run-lot.sh`** : le lanceur du développement. Il découpe le lot en passes [Claude Code](https://docs.claude.com/en/docs/claude-code)
  non interactives, une carte par passe, sur deux voies parallèles. Il fait tourner la suite complète une seule fois
  en fin de lot, puis lance la CI des pull requests du lot.
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
| 7 | Revue | relecteur | Relecture, tests, parcours Playwright sur la version déployée du lot ; verdict À MERGER ou À REPRENDRE. La 1re revue exige les preuves en réel du dev (`passe --reel`). Une revue de correction ne relit que le diff depuis la tête revue |
| 8 | Correction | dev | Revues 1 et 2 : tous les points, bloquants et non bloquants. À partir de la 3e revue : les bloquants seuls, chaque non bloquant devient une carte du lot suivant. Le dev corrige la famille de chaque défaut, pas le seul cas, et une passe distincte relit le diff de la reprise (`passe --contre-relecture`) |
| 9 | 7 ↔ 8 | | Automatique jusqu'à À MERGER ; arrêt au 5e À REPRENDRE |
| 10 | Merge du lot | relecteur, relais | Le verdict À MERGER merge aussitôt chaque PR dans la release (squash, back d'abord) ; le relais pose le commit de release (CHANGELOG, version) |
| 11 | Livraison | relais | Release verte : le relais ouvre les 4 PR, release vers `develop` et `master`, back et front. Le dev ne s'en charge que si une intervention de l'humain reste ouverte |
| 12 | Revue de livraison | relais ou relecteur | CI verte et contenu limité au lot revu : le relais merge les 4 PR. Sinon le relecteur vérifie et merge |
| 13 | Mise en production | relais, puis dev | CI de `develop` et `master` (déploiement compris), puis réglages de déploiement déclarés pendant le lot, posés et prouvés par le dev, et liste des validations visuelles à faire en production |
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
ce que la correction casse, oublie ou laisse passer.

**Voie courte.** Après le merge du lot, un correctif qui ne touche que la CI, les tests ou la documentation est reconnu
à ses fichiers (`motif_voie_courte`) : relu sur son diff, sans déploiement de preview ni contre-relecture, hors
compteur d'aller-retours. Le 3e À REPRENDRE de suite en voie courte arrête le cycle (`max_voie_courte`).

**Réglages de déploiement.** Les variables d'environnement, workflows à lancer, données à republier ou migrations
qu'une carte suppose se déclarent pendant le lot (`cycle-lot reglage <v> --ajouter …`), par le dev ou le relecteur. Un
réglage écrit seulement dans une PR s'oublie à la livraison : le passage aux validations en production est refusé tant
que chaque réglage n'est pas marqué fait avec sa preuve (`reglage <v> --fait N --preuve …`), et le relecteur les
vérifie en premier.

**Arrêts.** Le cycle s'arrête sur un arbitrage bloquant, sur une intervention nécessaire de l'humain (variable
d'environnement, jeton, compte…), au 5e verdict À REPRENDRE et au 3e À REPRENDRE de suite en voie courte. Les
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
- à la première CI de release verte d'un lot, le relais compare la plus longue durée mesurée de chaque job et de
  chaque étape plafonnée de la CI à son `timeout-minutes`, et poste un avis pour celles qui dépassent 80 % (`cycle-lot
  marges` donne le même tableau à la demande).

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
run-lot.sh <dossier-du-lot> impl   # voies A et B en parallèle, phase FIN, puis CI des PR du lot
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

**Phases.**

- **PRE** : études et mesures en tête de lot, sans implémentation. Les questions d'arbitrage vont dans
  `questions-arbitrage.md`. `impl` refuse de démarrer tant qu'elles ne sont pas tranchées dans `arbitrages.md`, ou
  qu'une question `[BLOQUANTE]` n'a pas de réponse de l'humain.
- **A et B** : deux voies en parallèle, une carte par passe. Une passe ne reçoit de la précédente que sa note de
  passation. Tests ciblés seulement. Quand les deux voies touchent le même dépôt, la voie B travaille dans son propre
  worktree, sur une branche `-vB`.
- **FIN** : fusion de la branche `-vB` (Claude résout les conflits si git n'y arrive pas seul), puis suite complète de
  chaque application touchée, et relecture du diff avec la grille de revue.
- **CI** : pendant le lot, une étiquette (`ci-en-pause`) fait sauter les jobs de PR et les runs déjà partis sont
  annulés. Les workflows doivent tester cette étiquette dans le `if:` de leurs jobs de PR. En fin de lot, le lanceur
  retire l'étiquette, rouvre les PR, attend les verdicts et les écrit dans son journal. Un rouge sans rapport avec le
  code (tâche Sonar tombée, coupure réseau) est relancé une fois.

**Créneaux.** Au plus `MAX_VOIES` passes Claude Code à la fois sur la machine, tous lots et tous agents confondus
(verrous `flock` dans `slots/`). Chaque passe exige `SEUIL_MIO` de mémoire disponible au démarrage. Un job lourd d'un
agent (unit dont le nom correspond à `AGENTS_RE`, et qui charge vraiment la machine) occupe un créneau.

Les passes tournent avec `claude --permission-mode bypassPermissions` : réservez le lanceur à une machine ou à un
compte dédiés aux agents.

Réglages de la machine : [`run-lot.example.conf`](run-lot.example.conf), à copier en `run-lot.conf`.

## `cycle-lot`

| Commande | Qui | Effet |
|---|---|---|
| `debut <v> --session-key <clé>` | dev, sur demande de l'humain | Crée l'état du lot, cartes en Work in progress |
| `passe <v> --vers <relecteur> --message … [--reel <f>\|aucun] [--contre-relecture <f>]` | dev | Fin du dev ou d'une correction : CI verte exigée, preuves en réel à la 1re revue, contre-relecture après une correction, back du lot déployé sur la preview (si `deploiement_preview` est configuré), puis revue. Un correctif en voie courte se passe de preview et de contre-relecture |
| `verdict <v> --merger\|--a-reprendre --rapport <f> [--bloquants N] [--non-bloquants N] [--cartes-ok …] [--cartes-ko …]` | relecteur | Fin de revue ; `--merger` merge aussitôt les PR du lot ; verdicts incohérents refusés ; arrêt automatique au 5e À REPRENDRE |
| `merge <v> --pr back#N` | relecteur | Merge gardé : tête inchangée depuis la revue, CI verte, back avant front ; après un merge refusé au verdict, ou en revue de livraison |
| `ouvrir-livraison <v>` | dev | Les 4 PR de livraison, quand le relais n'a pas pu les ouvrir ; refusé tant qu'une intervention de l'humain reste à faire |
| `passe <v> --vers <relecteur> --etape validation-prod --fichier <liste>` | dev | Liste des validations visuelles en production |
| `carte-bug <v> --titre … --appli … --gravite … --description-fichier … [--version-cible <v>]` | relecteur | Carte de bug dans la version suivante (ou celle donnée, postérieure), en Not Ready |
| `carte-report <v> --titre … --appli … --gravite … --description-fichier … [--version-cible <v>]` | relecteur ou dev | Point reporté à un lot suivant, à toute étape : non bloquant à partir de la 3e revue, défaut ancien hors périmètre, reste décidé par l'humain |
| `reglage <v> [--ajouter … \| --fait N --preuve …]` | dev ou relecteur | Réglages de déploiement : déclarés pendant le lot, exigés avant les validations en production ; sans option, la liste |
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
     avant le verdict, et le dev ne corrige que les bloquants.
5. La grille de revue commune est [`GRILLE-REVUE.md`](GRILLE-REVUE.md), et les règles d'arbitrage
   [`regles-arbitrage.example.md`](regles-arbitrage.example.md), à copier en `regles-arbitrage.md`.

## Prérequis

Linux avec systemd en mode utilisateur (cgroups v2), Python 3.11 ou plus (bibliothèque standard seule), bash, git,
la [CLI GitHub](https://cli.github.com) authentifiée, Claude Code pour `run-lot.sh`, et un gateway OpenClaw relié à
Slack pour `cycle-lot`. Les deux dépôts suivent un flux `develop` / `release/<version>` / `master`.

## Tests

```
python3 -I tests/scenario.py     # cycle-lot : cycle complet, refus, relances, arrêts, panne du gateway (134 vérifications)
bash tests/essai-run-lot.sh      # run-lot.sh de bout en bout, sur des dépôts git locaux (26 vérifications, ~1 min)
```

Aucun des deux n'appelle un vrai service : de faux `gh`, `openclaw`, `systemctl`, `claude` et une fausse API Trello
tiennent un monde en JSON.

## Licence

MIT, voir [LICENSE](LICENSE).
