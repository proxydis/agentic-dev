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
| 7 | Revue | relecteur | Relecture, tests, parcours Playwright sur la version déployée du lot ; verdict À MERGER ou À REPRENDRE. Une revue de correction ne relit que le diff depuis la tête revue |
| 8 | Correction | dev | Tous les points, bloquants et non bloquants, sur les mêmes PR |
| 9 | 7 ↔ 8 | | Automatique jusqu'à À MERGER ; arrêt au 3e À REPRENDRE |
| 10 | Merge du lot | relecteur, relais | Le verdict À MERGER merge aussitôt chaque PR dans la release (squash, back d'abord) ; le relais pose le commit de release (CHANGELOG, version) |
| 11 | Livraison | relais | Release verte : le relais ouvre les 4 PR, release vers `develop` et `master`, back et front. Le dev ne s'en charge que si une intervention de l'humain reste ouverte |
| 12 | Revue de livraison | relais ou relecteur | CI verte et contenu limité au lot revu : le relais merge les 4 PR. Sinon le relecteur vérifie et merge |
| 13 | Mise en production | relais, puis dev | CI de `develop` et `master` (déploiement compris), puis liste des validations visuelles à faire en production |
| 14 | Validation en production | relecteur | Playwright sur la production, une carte Trello par défaut, dans la version suivante, en Not Ready |

Trello suit le cycle : Work in progress au démarrage, Waiting for review dès qu'une passe est poussée dans la PR du
lot, Under review au début de la revue, Finished ou de nouveau Work in progress au verdict. Une carte validée ne bouge
plus.

**Arrêts.** Le cycle s'arrête sur un arbitrage bloquant, sur une intervention nécessaire de l'humain (variable
d'environnement, jeton, compte…) et au 3e verdict À REPRENDRE. Les arbitrages et les interventions se signalent dès le
démarrage du lot, pas au milieu. À l'arrêt, le relais poste un avis dans le fil et nomme l'agent à mentionner ; l'humain
répond en le mentionnant, et l'agent relance le cycle (`cycle-lot reprise`).

## Pourquoi un relais

Deux agents qui s'attendent mutuellement finissent par s'interbloquer. Il suffit que chacun écrive un script qui attend
l'autre (« j'attends la fin des jobs du dev », « j'attends le merge du relecteur ») pour que plus rien n'avance, en
silence. Ici, aucun agent n'attend jamais :

- un agent termine son étape par une commande `cycle-lot`, qui vérifie la transition, met à jour l'état du lot et
  planifie le réveil du suivant ;
- le relais (`cycle-lot veille`, toutes les 2 min, sous systemd) exécute les réveils et tient toutes les attentes, qui
  ne dépendent que de GitHub ;
- un agent qui ne donne plus signe de vie est relancé deux fois, puis l'humain est prévenu dans le fil.

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
| `passe <v> --vers <relecteur> --message …` | dev | Fin du dev ou d'une correction : CI verte exigée, back du lot déployé sur la preview (si `deploiement_preview` est configuré), puis revue |
| `verdict <v> --merger\|--a-reprendre --rapport <f> [--cartes-ok …] [--cartes-ko …]` | relecteur | Fin de revue ; `--merger` merge aussitôt les PR du lot ; arrêt automatique au 3e À REPRENDRE |
| `merge <v> --pr back#N` | relecteur | Merge gardé : tête inchangée depuis la revue, CI verte, back avant front ; après un merge refusé au verdict, ou en revue de livraison |
| `ouvrir-livraison <v>` | dev | Les 4 PR de livraison, quand le relais n'a pas pu les ouvrir ; refusé tant qu'une intervention de l'humain reste à faire |
| `passe <v> --vers <relecteur> --etape validation-prod --fichier <liste>` | dev | Liste des validations visuelles en production |
| `carte-bug <v> --titre … --appli … --gravite … --description-fichier …` | relecteur | Carte de bug dans la version suivante, en Not Ready |
| `fin <v> --rapport <f>` | relecteur | Lot livré et validé |
| `arret`, `reprise`, `intervention`, `programmer`, `reveiller` | | Arrêt et reprise, interventions de l'humain, lancement différé, réveil manuel |
| `etat [<v>] [--json]` | tous | Lecture seule |
| `veille` | relais | Le passage du timer |

L'état d'un lot vit dans `cycles/<version>/etat.json`, avec son journal `journal.log`. Le pouls du relais est dans
`cycles/.veille.json` (dernier passage, erreurs). La vue Graph d'[openclaw-task-monitor](https://github.com/proxydis/openclaw-task-monitor)
les lit pour montrer chaque lot, l'agent qui a la main et les runs que le relais attend.

**Installation.**

1. Copier [`cycle-lot.example.json`](cycle-lot.example.json) en `cycle-lot.json` et le remplir : les identifiants
   OpenClaw des deux agents et du compte qui poste les avis du relais, l'humain (nom, identifiant Slack), les dépôts
   GitHub et les jobs de CI exigés, les URL de production et de preview, les listes et étiquettes Trello. Les clés
   Trello se lisent dans l'environnement (`TRELLO_API_KEY`, `TRELLO_TOKEN`) ou dans la config d'OpenClaw.
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
     dossier du lot ou dans un rapport, jamais seulement dans le fil.
5. La grille de revue commune est [`GRILLE-REVUE.md`](GRILLE-REVUE.md), et les règles d'arbitrage
   [`regles-arbitrage.example.md`](regles-arbitrage.example.md), à copier en `regles-arbitrage.md`.

## Prérequis

Linux avec systemd en mode utilisateur (cgroups v2), Python 3.11 ou plus (bibliothèque standard seule), bash, git,
la [CLI GitHub](https://cli.github.com) authentifiée, Claude Code pour `run-lot.sh`, et un gateway OpenClaw relié à
Slack pour `cycle-lot`. Les deux dépôts suivent un flux `develop` / `release/<version>` / `master`.

## Tests

```
python3 -I tests/scenario.py     # cycle-lot : cycle complet, refus, relances, arrêts, panne du gateway (75 vérifications)
bash tests/essai-run-lot.sh      # run-lot.sh de bout en bout, sur des dépôts git locaux (22 vérifications, ~1 min)
```

Aucun des deux n'appelle un vrai service : de faux `gh`, `openclaw`, `systemctl`, `claude` et une fausse API Trello
tiennent un monde en JSON.

## Licence

MIT, voir [LICENSE](LICENSE).
