# agentic-dev

*[Version française](README.fr.md)*

Two tools that let two AI agents, a developer and a reviewer, build, review and ship a batch of cards, from
"start batch 1.0.0" to validation in production. The human starts the batch and only comes back for the decisions
that are theirs to make.

- **`run-lot.sh`**: the development launcher. It splits the batch into non-interactive
  [Claude Code](https://docs.claude.com/en/docs/claude-code) passes, one card per pass, on two or three parallel
  lanes. It runs the full test suite only once, at the end of the batch, from a script and without Claude, then starts
  the CI of the batch pull requests.
- **`cycle-lot`**: the full cycle, from review to production. One state machine per batch, moved forward by the agents
  through commands, and a systemd relay that wakes each agent when its turn comes and owns every wait (CI,
  deployments).

Both tools were written for [OpenClaw](https://docs.openclaw.ai) agents working in Slack, on two GitHub repositories
(back and front), with a Trello board. Everything specific to an installation lives in unversioned configuration files.
The scripts, their messages and the prompts they build are in French.

## The cycle of a batch

| # | Step | Who | What happens |
|---|---|---|---|
| 1 | Start | dev | `cycle-lot debut`: batch cards to Work in progress, `release/<version>` branches cut from `develop` |
| 2 | Development | dev | `run-lot.sh pre`, then `impl`: `feat/…` branches cut from the release, pull requests into the release |
| 3 | Arbitration | dev | The dev settles questions with the project rules (`regles-arbitrage.md`) and records each decision |
| 4 | Blocking question | dev → human | A question the rules cannot settle stops the cycle (`cycle-lot arret`) |
| 5 | End-of-batch CI | `run-lot.sh` | Unit and e2e tests, quality and security analysis, once, on the final heads of the PRs |
| 6 | Red CI | dev | The dev fixes it before asking for review: `cycle-lot passe` refuses a CI that is not green |
| 7 | Review | reviewer | Code review, tests, Playwright journeys on the deployed batch; verdict MERGE or REWORK. The first review requires the dev's real-world evidence (`passe --reel`), and every later review requires it again on the rework head. A rework review only reads the diff since the reviewed head |
| 8 | Rework | dev | Reviews 1 and 2: every point, blocking or not. From the 3rd review: blocking points only, each non-blocking point is a card of the next batch. The dev fixes the family of each defect, not the single case, and a separate pass re-reads the rework diff (`passe --contre-relecture`) |
| 9 | 7 ↔ 8 | | Automatic until MERGE; stops at the 5th REWORK |
| 10 | Batch merge | reviewer, relay | The MERGE verdict immediately merges each PR into the release (squash, back first); the relay adds the release commit (CHANGELOG, version) |
| 10b | Red release CI | dev | Each red hands over to the dev with the runs, the red jobs and the count of reds in a row: a fix through a PR, or a re-run then `cycle-lot attendre-ci`. From the 3rd red in a row, a written diagnosis comes before any re-run |
| 11 | Delivery | relay | Green release: the relay opens the 4 PRs, release into `develop` and `master`, back and front. The dev only steps in while a human action or a pre-delivery deployment setting is still pending |
| 12 | Delivery review | relay or reviewer | Green CI and content limited to the reviewed batch: the relay merges the 4 PRs. Otherwise the reviewer checks and merges |
| 13 | Production | relay, then dev | CI of `develop` and `master` (deployment included), then the remaining deployment settings (those that can only be set after the deployment), set and proven by the dev, and the list of visual checks to run in production |
| 13b | Deployment diagnosis | dev | Red production CI (step `diagnostic-deploiement`): the dev diagnoses, re-runs, then `cycle-lot attendre-ci --message "<diagnosis>"` hands the wait back to the relay |
| 14 | Production checks | reviewer | Playwright on production, one Trello card per defect, in the next version, in Not Ready |

Trello follows the cycle: Work in progress at start, Waiting for review as soon as a pass is pushed to the batch PR
(steps A, B and FIN), Under review when the review starts, Finished or back to Work in progress at the verdict. MERGE
only moves to Finished the cards still in the batch flow (Work in progress, Waiting for review, Under review); a card
left in Not Ready, Standby, Blocked or Canceled does not move, and the command reports it. A validated card never
moves again.

**Deferring a card.** Rename it to its new version (`[V1.0.1-…]`) and move it back to Not Ready. Until the MERGE
verdict, every read of the board (relay, `passe`, `verdict`) aligns the batch card list with the titles: the card
leaves the batch (one journal line, out of the progress total, "Sorties du lot" in `cycle-lot etat`) and comes back if
it is given the batch version again.

**Review rule.** At most 5 round trips (`max_aller_retours`). At reviews 1 and 2, everything gets fixed: REWORK as
soon as a blocking or non-blocking point remains. From the 3rd review on (`revue_report_non_bloquants`), only a
blocking point sends the batch back; the reviewer turns each non-blocking point into a card of the next batch
(`cycle-lot carte-report`) during the review, and the dev only fixes the blocking points. `verdict` takes
`--bloquants` and `--non-bloquants` and refuses inconsistent verdicts: REWORK without the number of blocking points,
MERGE with non-blocking points at reviews 1 and 2, REWORK without a blocking point from the 3rd review, more
non-blocking points than cards created during the review. A point found after the 1st review in code unchanged since
then is non-blocking, unless it touches security.

**Before the review.** The first handover to review requires the real-world evidence of the batch (`passe --reel
<file>`): for each card that depends on an external service (AI model, hosted database, e-mail, captcha, data source,
storage), the command or journey played on pre-production and its result, or `--reel aucun`. A human action without
which a card cannot be checked for real is declared with `intervention --ajouter … --avant revue`: the review is
refused until it is done, or until the cards that depend on it are deferred. After a rework, `passe` requires the
report of a counter-review (`--contre-relecture <file>`): a separate pass that read the rework diff with the review
grid, asking only what the fix breaks, misses or lets through. When the first handover gave an evidence file, every
return to review brings its own: `--reel <file>` with the evidence replayed on the rework head, or `--reel inchange
--motif "<why the rework touches no criterion played for real>"` (20 characters at least). The reviewer's instructions
quote the file, or the reason to check against the diff; a false reason is a blocking point. The short lane is exempt.

**Playing the evidence: `run-reel.sh`.** `run-reel.sh <folder> [<evidence file>]` starts at the same time one Claude
pass per `step-REEL<suffix>.md` instruction in the folder (for example one for the back's real model draws, one for the
Playwright journeys on the preview), waits for all of them, then appends their sections, in name order, to the end of
the evidence file. Each pass only writes its own section (`<folder>/reel<suffix>.md`). The frame added to every
instruction asks for independent draws to run at the same time. When a server-side cache would serve an identical draw
again, each draw must be made distinct by an input with no effect on the criterion (a departure time shifted by a few
minutes) instead of waiting for the cache to expire: three draws 31 min apart behind a 30 min cache made a one-hour
pass, almost all of it waiting. `REEL_PARTAGE` names the quotas the passes share. Test: `bash tests/essai-run-reel.sh`.

**Short lane.** After the batch is merged, a fix that only touches CI, tests or documentation is recognized from its
files (`motif_voie_courte`, which includes the scripts only CI runs, `scripts/ci/`): reviewed on its diff, with no preview deployment and no counter-review, outside the
round-trip counter. The 3rd REWORK in a row on the short lane stops the cycle (`max_voie_courte`).

**Deployment settings.** Environment variables, workflows to run, data to republish or migrations that a card
requires are declared during the batch (`cycle-lot reglage <v> --ajouter …`), by the dev or the reviewer, with who
has to set them (`--qui dev`, the default, or `--qui humain`). A setting only written in a PR description gets
forgotten at delivery, and the delivery CI then finds them one by one, one red each. So `ouvrir-livraison`, and the
relay when it opens the delivery PRs itself, refuse while a setting to be set before delivery is still pending, and
list each one with who has to set it; the relay wakes the dev with that list instead of opening the PRs. A setting
that can only be set after the deployment (a workflow to run on `master`, data to publish on the served version) is
declared with `--apres-deploiement`, or reclassified (`reglage <v> --classer N --apres-deploiement`): it does not block
the delivery. `ouvrir-livraison <v> --sans-reglages "<reason>"` overrides the check, with the reason and the skipped
settings in the batch log; the relay never overrides it. Every setting, after deployment ones included, must be marked
done with its proof (`reglage <v> --fait N --preuve …`) before the handover to production checks, and the reviewer
checks them first.

**Red CI.** Each red of the release CI or of the production CI hands over to the dev, with the run, the red jobs and
the count of reds in a row (`relais.diagnostic_ci_rouges`, reset to zero when these CIs turn green). From the 3rd red
in a row, the instructions require a written diagnosis in the thread before any re-run: the cause of each red job,
how it differs from the previous reds, and why the next step will pass; `attendre-ci` refuses without it. A code defect
goes through a PR and `passe`; a red unrelated to the code is re-run (`gh run rerun <id> --failed`, or without
`--failed` when its machine went away), then `cycle-lot attendre-ci <v> --message "<diagnosis>"` hands the wait back to
the relay, on the release CI (from the rework step) or on the production CI (from `diagnostic-deploiement`, same
commits). The relay never stops the cycle for a red: only the dev stops it (`cycle-lot arret --motif ci|deploiement`)
when they need a decision or an action from the human.

**Stops.** The cycle stops on a blocking question, when the human has to act (environment variable, token,
account…), at the 5th REWORK verdict, at the 3rd REWORK in a row on the short lane, and when a release or production
CI has no verdict at all after twice the step's cap. A red CI never stops it. Questions and required human
actions are raised at the start of the batch, not halfway through. On a stop, the relay posts a notice in the thread
naming the agent to mention, and sends it to the human as a direct message too; the human answers in the thread by
mentioning that agent, which resumes the cycle (`cycle-lot reprise`).

## Why a relay

Two agents that wait for each other end up deadlocked. It only takes each of them writing a script that waits for the
other ("I wait until the dev's jobs are done", "I wait until the reviewer merges") for everything to stall, silently.
Here, no agent ever waits:

- an agent ends its step with a `cycle-lot` command, which checks the transition, updates the batch state and
  schedules the next agent's wake-up;
- the relay (`cycle-lot veille`, every 2 minutes, under systemd) performs the wake-ups and owns every wait, which
  only depends on GitHub;
- an agent that stops showing signs of life is nudged twice, then the human is alerted in the thread and by direct
  message, again every 2 hours (5 reminders at most). Any sign of life (a job or a turn) re-arms the nudges;
- when the CI of the batch PRs is green on heads the reviewer has not seen, with no job or turn from the dev and no
  handover, the relay wakes the dev after 15 minutes instead of 45 (twice at most per set of heads);
- a red run on the code is acted on at once, without waiting for the other repository's runs. Without any red, a
  wait past the step's cap only posts a notice; the stop comes at twice the cap (runs queued on a single runner are
  not an outage);
- a front deployment refused because the back of the same branch is not deployed yet is the normal delivery order,
  not a red. It is recognized from the messages the front workflow writes (`motif_front_attend_back`) when the
  deployment job is the only red one and the back run of the same branch is running, not created yet, or green. The
  relay waits for the back, re-runs the front's red jobs once `relais.attente_back_min` after the back turned green,
  and only wakes the dev if the front turns red again;
- when the machine of a run went away, re-running the failed jobs alone would send them back to the same machine: the
  relay re-runs the whole run (`gh run rerun <id>` without `--failed`), once per run, and logs it. Triggers: a runner
  lost during the run ("lost communication with the server", in the log or the job annotations), the local machine
  refusing the run for lack of resources (a mark written by the workflow, `motif_machine_refusee`), or jobs queued for
  `relais.file_hors_ligne_min` on labels whose runners are all offline (the run is cancelled, then re-run whole on the
  next pass). Never when a deployment job (`jobs_deploiement`) has already started: the dev is told once instead;
- a required job queued for `relais.file_runner_libre_min` while a runner carrying its labels is online and idle is
  reported once to the dev (run, job, expected label, runners seen), with no automatic action and no message to the
  human. This watch covers the relay's waits and the CI of the batch PRs during development and rework; it reads
  `actions/runs/<id>/jobs` and `actions/runners`, which needs a token allowed to list the repository's runners
  (otherwise the read fails silently and nothing is reported);
- with a CI that routes its runs (a routing job at the head of the run picks the machine, tests may be split into a
  matrix of slices, a static analysis job may carry the gate), a run that has the routing job (`ci_aiguillage.job`,
  even skipped) also requires the `ci_aiguillage.jobs_requis` of its application and every test slice present
  (`ci_aiguillage.motif_tranches`); the marker job may skip them legitimately. A run without the routing job keeps the
  rules above;
- at the first green release CI of a batch, the relay compares the longest measured duration of each CI job and
  capped step with its `timeout-minutes`, and posts a notice for those above 80% (`cycle-lot marges` shows the same
  table on demand). The jobs of a matrix (`tests-1`, `tests-2`… from a job named `tests-${{ matrix.slice }}`) are
  measured against the cap of their job.

The wake-up goes through the OpenClaw gateway `agent` RPC, into the agent's session for the batch's Slack thread, and
the agent's reply is posted there. It runs from the systemd service, not from an agent's exec: the gateway refuses to
let an agent wake another session itself.

## Saving tokens

Over a batch, an agent's session in the batch thread quickly grows past 100k tokens, and every turn rewrites that
context into the cache: that is most of a turn's cost, far more than the work itself. The relay cuts both.

- **Fresh context at every step.** Before a wake-up that opens a step (review, rework, delivery…), the relay resets
  the agent's session in the thread (`sessions.reset` RPC, on the `sessionId` read just before; routing to the thread
  is kept). The agent starts again from its bootstrap context alone, and the relay's instructions are self-contained:
  batch state, PRs, reports, commands. If a turn of the agent is running, the relay waits for it to end (30 minutes at
  most) rather than interrupt it. Nudges and end-of-job wake-ups keep the session. `CYCLE_LOT_CONTEXTE_NEUF=0`
  turns this off.
- **Mechanical steps without an agent turn.** The MERGE verdict merges in the same command. The relay adds the release
  commit through the GitHub Git data API (the CHANGELOG `[Unreleased]` section moved under `[<version>] - date`, the
  `package.json` version), opens the delivery PRs, then merges them once their CI is green and every release commit
  missing from `develop` is a reviewed merge or that release commit. Each step is announced in the thread; a mismatch or
  a red CI wakes the reviewer.
- **Targeted rework review.** The verdict records the head of each reviewed PR; on the next review, the relay gives the
  reviewer the `git diff <reviewed head>..<current head>` range of each PR instead of asking for a full review.
- **Preview deployment only.** The preview dispatch passes `deploiement_seul=true` (input name:
  `deploiement_preview.entree_deploiement_seul`): the workflow can skip its tests when the commit already has a green
  run, which is the case after `passe`. A workflow without that input refuses the dispatch, and the relay runs it
  again without it.
- **Already validated content.** A workflow may skip its test jobs when the same git tree already has a green run (a
  delivery PR, a push to `develop` or `master`). It then runs a marker job (`job_deja_valide`, default
  `contenu-deja-valide`) whose success makes the skipped jobs listed in `jobs_sautables` acceptable. Without the
  marker, a skipped required job is still a missing job.
- **Review job without progress monitoring.** `claude --print --disallowedTools Monitor`: progress notifications woke
  the review orchestrator for nothing; only sub-agent and background command completions wake it.

## `run-lot.sh`

```
run-lot.sh <batch-folder> pre    # PRE phase only: studies, measurements, arbitration questions
run-lot.sh <batch-folder> impl   # lanes A, B (and C) in parallel, FIN phase, then CI of the batch PRs
```

The launcher runs in a systemd unit whose name starts with the agent id (`dev-100-impl`), with a memory cap and an
end hook that wakes the agent:

```
systemd-run --user --unit dev-100-impl --property=MemoryHigh=6G --property=MemoryMax=7G \
  --setenv=TRELLO_API_KEY=… --setenv=TRELLO_TOKEN=… \
  --property=ExecStopPost="<command that wakes the agent>" \
  bash ~/agentic-dev/run-lot.sh ~/batches/1.0.0 impl
```

**The batch folder** (full example in [`exemple-lot/`](exemple-lot)):

| File | Role |
|---|---|
| `lot.conf` | `VERSION`, `REL` (release branch), `PREFIX` (log prefix), `REPO_BACK`, `REPO_FRONT`, `LOGS`, and the `CARTE` table (card number → Trello id) |
| `etapes.txt` | One step per line: `<name> <phase> <repo> <card\|-> <branch> <base> [opt]`, re-read at each step (editable while running) |
| `step-<name>.md` | The step's instructions |
| `card-<n>.md` | The card's text |
| `common-back.md`, `common-front.md` | The shared frame of each application's passes |
| `arbitrages.md` | The agent's decisions and the human's answers, attached to every pass |
| `fin-mecanique-<app>.txt` | Optional: the batch's own list of end-of-batch commands, instead of the one next to `fin-mecanique.sh` |

**Phases.**

- **PRE**: studies and measurements before any implementation. Arbitration questions go to `questions-arbitrage.md`.
  `impl` refuses to start until they are settled in `arbitrages.md`, or while a `[BLOQUANTE]` question has no answer
  from the human.
- **A, B and C**: two or three parallel lanes, one card per pass. A pass only receives the previous pass's handoff
  note. Targeted tests only (`WORKERS_VOIE` workers, `WORKERS_3VOIES` with three lanes). Lane C is optional: a third
  queue of cards independent from the other two, started only if `etapes.txt` gives it steps. When a lane touches a
  repository already used by an earlier lane, it works in its own worktree, on its own branch (`-vB`, `-vC`); `impl`
  refuses two lanes on the same branch of the same repository. The launcher's git operations (fetch, worktree,
  checkout) run one at a time per repository, since the lanes share each repository's `.git`.
- **FIN**: merge of the `-vB` and `-vC` branches (`FUSION…` steps; Claude resolves conflicts when git cannot), cards
  placed at the end, then the end of each application: a FIN step without a card.
- **End of an application, in script** (when `MECA`, by default `fin-mecanique.sh`, is executable): first a review
  pass by Claude if the step has its `step-<name>.md`, with targeted tests only; then the mechanical part, played by
  `fin-mecanique.sh` without Claude: the command list `fin-mecanique-<app>.txt` (full suite, lint, typing, build, e2e,
  audit…, `WORKERS_FIN` workers), plus the PR's conflict state against the release; then, only if something is red, a
  fix pass that receives the report, and the script again, `MAX_TOURS_FIN` times at most. The full suite thus runs
  only once when everything is green, and a Claude pass no longer keeps hours of commands to itself. With `MECA` empty,
  the FIN pass runs the suite itself, as before.
- **Review of a rework**: the end-of-application review reads the whole batch diff the first time, and only the
  rework's diff (`git diff <head before>..HEAD`) when the batch is a rework. In a `cycle-lot` cycle, the head before is
  recorded on its own at the first launch of a `PREFIX` while the cycle is in rework; otherwise give it in `lot.conf`
  (`REPRISE_DEPUIS_BACK`, `REPRISE_DEPUIS_FRONT`; `-` forces a review of the whole batch).
- **CI**: during the batch, a label (`ci-en-pause`) makes the PR jobs skip and cancels runs already started. Your
  workflows must test that label in the `if:` of their PR jobs. At the end of the batch, the launcher removes the
  label, reopens the PRs, waits for the verdicts and writes them to its log. A red unrelated to the code (Sonar task
  failure, network outage) is re-run once.

**Slots.** At most `MAX_VOIES` (3) Claude Code passes at once on the machine, across all batches and agents (`flock`
locks in `slots/`). Each pass needs `SEUIL_MIO` of available memory when it starts. A heavy job from an agent (a unit
whose name matches `AGENTS_RE` and that actually loads the machine) takes a slot.

Passes run with `claude --permission-mode bypassPermissions`: keep the launcher on a machine or an account dedicated to
the agents.

Machine settings: [`run-lot.example.conf`](run-lot.example.conf), to copy as `run-lot.conf`.

**`fin-mecanique.sh`.** `fin-mecanique.sh <back|front> <repository> <base> <log folder> [<list>]` plays every command
of the list in order, in the repository, even after a red (the fix pass gets the whole list at once), and writes a
Markdown report on its standard output; each command has its own log. One line per command:
`<name> [apres=<name>] [sortie2=non-joue] | <shell command>`: `apres=` skips the command when the named one is not
green (e2e after build), `sortie2=non-joue` reads exit code 2 as "could not run" rather than red. The commands get
`$W` (workers), `$J` (log folder), `$T` (temporary folder of the run), `$BASE`, `$E2E_PORT` and `$VERIF`. `$T` lives
under `MECA_TMP` (default `~/.cache/run-lot/meca`), outside `/tmp` (often a small tmpfs) and outside any git
repository (tests that run `git ls-files` in their temporary folder would see the enclosing repository): the script
refuses to run inside a git repository, and deletes `$T` on exit. It does not start either when the disk holding `$T`
has less than `MECA_DISQUE_MIO` free (exit 2: nothing played), since a full disk would give false reds. Each command is
capped at `MECA_DELAI_S` seconds. Exit 0: all green; 1: at least one red; 2: nothing could be played. Example lists for
a Python back and a Node front: [`fin-mecanique-back.txt`](fin-mecanique-back.txt),
[`fin-mecanique-front.txt`](fin-mecanique-front.txt).

## `cycle-lot`

| Command | Who | Effect |
|---|---|---|
| `debut <v> --session-key <key>` | dev, when the human asks | Creates the batch state, cards to Work in progress |
| `passe <v> --vers <reviewer> --message … [--reel <f>\|aucun\|inchange --motif …] [--contre-relecture <f>]` | dev | End of development or rework: green CI required, real-world evidence at the first review and again at each return to review (`--reel <f>`, or `--reel inchange --motif "<reason>"`), counter-review after a rework, batch back end deployed to preview (when `deploiement_preview` is configured), then review. A short-lane fix skips the preview and the counter-review |
| `verdict <v> --merger\|--a-reprendre --rapport <f> [--bloquants N] [--non-bloquants N] [--cartes-ok …] [--cartes-ko …]` | reviewer | End of review; `--merger` immediately merges the batch PRs; inconsistent verdicts refused; automatic stop at the 5th REWORK |
| `merge <v> --pr back#N` | reviewer | Guarded merge: head unchanged since the review, green CI, back before front; after a merge refused at the verdict, or in delivery review |
| `ouvrir-livraison <v> [--sans-reglages "<reason>"]` | dev | The 4 delivery PRs, when the relay could not open them; refused while a human action or a pre-delivery deployment setting is still pending (`--sans-reglages` overrides the settings check, with a reason kept in the log) |
| `attendre-ci <v> --message "<diagnosis>"` | dev or reviewer | After a re-run, hands the CI wait back to the relay: reviewer in delivery review; dev after a red release CI (rework step) or a red production CI (`diagnostic-deploiement`). From the 3rd red in a row, the diagnosis is required |
| `passe <v> --vers <reviewer> --etape validation-prod --fichier <list>` | dev | List of visual checks in production |
| `carte-bug <v> --titre … --appli … --gravite … --description-fichier … [--version-cible <v>]` | reviewer | Bug card in the next version (or the given later one), in Not Ready |
| `carte-report <v> --titre … --appli … --gravite … --description-fichier … [--version-cible <v>]` | reviewer or dev | Point deferred to a later batch, at any step: non-blocking point from the 3rd review, old defect out of scope, leftover decided by the human |
| `reglage <v> [--ajouter … [--apres-deploiement] [--qui dev\|humain] \| --fait N --preuve … \| --classer N [--apres-deploiement] [--qui …]]` | dev or reviewer | Deployment settings: declared during the batch, required before the delivery PRs open (or, declared `--apres-deploiement`, before production checks); `--classer` reclassifies one; without an option, the list with who sets each one and when |
| `marges [--ref develop]` | anyone | Longest measured duration of each CI job and capped step over the last green runs, against its `timeout-minutes` |
| `fin <v> --rapport <f>` | reviewer | Batch delivered and validated |
| `arret`, `reprise`, `intervention [--avant revue]`, `programmer`, `reveiller` | | Stop and resume, human actions (required before the review with `--avant revue`, before delivery by default), deferred start, manual wake-up |
| `etat [<v>] [--json]` | anyone | Read only |
| `veille` | relay | One pass of the timer |

A batch's state lives in `cycles/<version>/etat.json`, next to its log `journal.log`. The relay's heartbeat is
`cycles/.veille.json` (last pass, errors). The Graph view of
[openclaw-task-monitor](https://github.com/proxydis/openclaw-task-monitor) reads them to show each batch, the agent
holding the hand, the runs the relay is waiting for and the batch progress.

**Progress.** On each pass, the relay reads the Trello board (one read, outside the locks) and writes `avancement`
into the state of each running batch: cards done by the dev out of the batch cards, count per list, list of each card
and time of the reading. A card is done once `run-lot.sh` has moved it to Waiting for review (its pass is pushed), or
further (Under review, Finished); sent back to Work in progress at the verdict, it is counted as not done again;
canceled or archived, it leaves the total. A failed read keeps the last count and records the error, without counting
as a relay error.

**Installation.**

1. Copy [`cycle-lot.example.json`](cycle-lot.example.json) to `cycle-lot.json` and fill it in: the OpenClaw ids of
   both agents and of the account that posts the relay's notices, the human (name, Slack id), the GitHub repositories
   and required CI jobs, production and preview URLs, Trello lists and labels. Trello keys are read from the
   environment (`TRELLO_API_KEY`, `TRELLO_TOKEN`) or from the OpenClaw config. Optional keys, with their default:

   | Key | Default | Role |
   |---|---|---|
   | `max_aller_retours` | 5 | REWORK verdicts before the cycle stops |
   | `revue_report_non_bloquants` | 3 | Review from which non-blocking points become next-batch cards |
   | `max_voie_courte` | 3 | REWORK verdicts in a row on the short lane before the cycle stops |
   | `motif_voie_courte` | CI, tests, docs | Regular expression on file paths: a post-merge fix whose files all match takes the short lane |
   | `job_deja_valide` | `contenu-deja-valide` | Marker job of a workflow that skipped its tests on already validated content |
   | `jobs_sautables` | `["quality", "e2e"]` | Required jobs that may be skipped when the marker job succeeded |
   | `deploiement_preview.entree_deploiement_seul` | `deploiement_seul` | `workflow_dispatch` input for a deployment only; empty: plain dispatch |
   | `relais.ci_verte_min` | 15 | Minutes of green CI without handover before the dev's targeted wake-up |
   | `relais.rappel_alerte_min`, `relais.nb_rappels_alerte` | 120, 5 | Reminders of an unanswered alert, in the thread and by direct message |
   | `relais.seuil_marge` | 0.8 | Share of a `timeout-minutes` above which a CI duration gets a notice |
   | `relais.diagnostic_ci_rouges` | 3 | Reds in a row of the release or production CI from which a written diagnosis is required before any re-run |
   | `relais.attente_back_min` | 10 | Minutes after the back turned green before the front deployment that waited for it is re-run |
   | `relais.file_hors_ligne_min` | 10 | Minutes of jobs queued on offline machines before the run is cancelled and re-run whole |
   | `relais.file_runner_libre_min` | 15 | Minutes a required job may stay queued while a matching runner is idle before the dev is told |
   | `jobs_deploiement` | `["deploy"]` | Jobs that deploy: a run where one of them started is never cancelled nor re-run whole; the only red job allowed when the front waits for the back |
   | `motif_front_attend_back` | `ATTENTE-BACK` | Regular expression on the log of the front's red jobs: deployment refused because the back of the same branch is not deployed yet |
   | `motif_machine_refusee` | none | Regular expression on the log of red jobs: the run's machine refused it for lack of resources (whole re-run) |
   | `ci_aiguillage.job` | none | Routing job of a CI that picks the machine of each run; absent, the rules of a routed CI do not apply |
   | `ci_aiguillage.jobs_requis` | `{}` | Per application, jobs required (and skippable with the marker job) in a routed run |
   | `ci_aiguillage.motif_tranches` | none | Regular expression of test slice names (`^tranche-\d+$`): every slice present in a routed run is required |
   | `slack_archives` | none | `https://<workspace>.slack.com/archives`: link to the thread in direct messages; absent, the message has no link (`CYCLE_LOT_SLACK_ARCHIVES` overrides it) |
2. Make the command available to the agents: `ln -s ~/agentic-dev/cycle-lot ~/.local/bin/cycle-lot`.
3. Install the relay: copy [`systemd/`](systemd) into `~/.config/systemd/user/`, adjust the path, then
   `systemctl --user enable --now cycle-lot-relais.timer`.
4. Give the agents their instructions (in their `AGENTS.md`):
   - a `[RELAIS DU CYCLE DE LOT …]` message is addressed to them even without a mention, and a reply is mandatory;
   - the hand only passes through `cycle-lot`, never through a Slack mention, because a mention between agents does
     not start a turn;
   - no script or unit that waits for the other agent or for CI: the relay does the waiting;
   - never call the gateway `agent` RPC directly from an exec;
   - any work longer than 30 minutes runs in a `<agent>-<prefix>-…` unit (`dev-100-impl`, `relecteur-100-rev1`),
     otherwise the relay thinks the agent is idle and nudges it;
   - the thread session is reset at every step: whatever a later step needs goes into the batch folder or a report,
     never only into the thread;
   - from the review rule's report threshold on, the reviewer creates one `carte-report` per non-blocking point
     before the verdict, and the dev only fixes the blocking points;
   - after a red CI, the dev diagnoses, fixes through a PR or re-runs, then hands the wait back with `cycle-lot
     attendre-ci --message "<diagnosis>"`; from the 3rd red in a row, the written diagnosis is posted in the thread
     first, and `cycle-lot arret` is only for a decision or an action of the human;
   - every return to review brings its real-world evidence (`--reel <file>` or `--reel inchange --motif …`), and a
     deployment setting that can only be set after the deployment is declared `--apres-deploiement`.
5. The shared review grid is [`GRILLE-REVUE.md`](GRILLE-REVUE.md), and the arbitration rules
   [`regles-arbitrage.example.md`](regles-arbitrage.example.md), to copy as `regles-arbitrage.md`.

## Requirements

Linux with user-mode systemd (cgroups v2), Python 3.11 or later (standard library only), bash, git, an authenticated
[GitHub CLI](https://cli.github.com), Claude Code for `run-lot.sh`, and an OpenClaw gateway connected to Slack for
`cycle-lot`. Both repositories follow a `develop` / `release/<version>` / `master` flow.

## Tests

```
python3 -I tests/scenario.py     # cycle-lot: full cycle, refusals, nudges, stops, red CI, gateway outage (177 checks)
bash tests/essai-run-lot.sh      # run-lot.sh end to end, on local git repositories: three lanes, end of batch in
                                 # script, rework reviewed on its diff (47 checks, ~2 min)
```

Neither calls a real service: fake `gh`, `openclaw`, `systemctl` and `claude` commands and a fake Trello API share a
JSON world.

## License

MIT, see [LICENSE](LICENSE).
