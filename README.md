# agentic-dev

*[Version française](README.fr.md)*

Two tools that let two AI agents, a developer and a reviewer, build, review and ship a batch of cards, from
"start batch 1.0.0" to validation in production. The human starts the batch and only comes back for the decisions
that are theirs to make.

- **`run-lot.sh`**: the development launcher. It splits the batch into non-interactive
  [Claude Code](https://docs.claude.com/en/docs/claude-code) passes, one card per pass, on two parallel lanes. It
  runs the full test suite only once, at the end of the batch, then starts the CI of the batch pull requests.
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
| 7 | Review | reviewer | Code review, tests, Playwright journeys on the deployed batch; verdict MERGE or REWORK. The first review requires the dev's real-world evidence (`passe --reel`). A rework review only reads the diff since the reviewed head |
| 8 | Rework | dev | Reviews 1 and 2: every point, blocking or not. From the 3rd review: blocking points only, each non-blocking point is a card of the next batch. The dev fixes the family of each defect, not the single case, and a separate pass re-reads the rework diff (`passe --contre-relecture`) |
| 9 | 7 ↔ 8 | | Automatic until MERGE; stops at the 5th REWORK |
| 10 | Batch merge | reviewer, relay | The MERGE verdict immediately merges each PR into the release (squash, back first); the relay adds the release commit (CHANGELOG, version) |
| 11 | Delivery | relay | Green release: the relay opens the 4 PRs, release into `develop` and `master`, back and front. The dev only steps in while a human action is still pending |
| 12 | Delivery review | relay or reviewer | Green CI and content limited to the reviewed batch: the relay merges the 4 PRs. Otherwise the reviewer checks and merges |
| 13 | Production | relay, then dev | CI of `develop` and `master` (deployment included), then the deployment settings declared during the batch, set and proven by the dev, and the list of visual checks to run in production |
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
grid, asking only what the fix breaks, misses or lets through.

**Short lane.** After the batch is merged, a fix that only touches CI, tests or documentation is recognized from its
files (`motif_voie_courte`): reviewed on its diff, with no preview deployment and no counter-review, outside the
round-trip counter. The 3rd REWORK in a row on the short lane stops the cycle (`max_voie_courte`).

**Deployment settings.** Environment variables, workflows to run, data to republish or migrations that a card
requires are declared during the batch (`cycle-lot reglage <v> --ajouter …`), by the dev or the reviewer. A setting
only written in a PR description gets forgotten at delivery: the handover to production checks is refused until each
setting is marked done with its proof (`reglage <v> --fait N --preuve …`), and the reviewer checks them first.

**Stops.** The cycle stops on a blocking question, when the human has to act (environment variable, token,
account…), at the 5th REWORK verdict, and at the 3rd REWORK in a row on the short lane. Questions and required human
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
- at the first green release CI of a batch, the relay compares the longest measured duration of each CI job and
  capped step with its `timeout-minutes`, and posts a notice for those above 80% (`cycle-lot marges` shows the same
  table on demand).

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
run-lot.sh <batch-folder> impl   # lanes A and B in parallel, FIN phase, then CI of the batch PRs
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

**Phases.**

- **PRE**: studies and measurements before any implementation. Arbitration questions go to `questions-arbitrage.md`.
  `impl` refuses to start until they are settled in `arbitrages.md`, or while a `[BLOQUANTE]` question has no answer
  from the human.
- **A and B**: two parallel lanes, one card per pass. A pass only receives the previous pass's handoff note. Targeted
  tests only. When both lanes touch the same repository, lane B works in its own worktree, on a `-vB` branch.
- **FIN**: merge of the `-vB` branch (Claude resolves conflicts when git cannot), then the full suite of each touched
  application, and a review of the diff against the review grid.
- **CI**: during the batch, a label (`ci-en-pause`) makes the PR jobs skip and cancels runs already started. Your
  workflows must test that label in the `if:` of their PR jobs. At the end of the batch, the launcher removes the
  label, reopens the PRs, waits for the verdicts and writes them to its log. A red unrelated to the code (Sonar task
  failure, network outage) is re-run once.

**Slots.** At most `MAX_VOIES` Claude Code passes at once on the machine, across all batches and agents (`flock`
locks in `slots/`). Each pass needs `SEUIL_MIO` of available memory when it starts. A heavy job from an agent (a unit
whose name matches `AGENTS_RE` and that actually loads the machine) takes a slot.

Passes run with `claude --permission-mode bypassPermissions`: keep the launcher on a machine or an account dedicated to
the agents.

Machine settings: [`run-lot.example.conf`](run-lot.example.conf), to copy as `run-lot.conf`.

## `cycle-lot`

| Command | Who | Effect |
|---|---|---|
| `debut <v> --session-key <key>` | dev, when the human asks | Creates the batch state, cards to Work in progress |
| `passe <v> --vers <reviewer> --message … [--reel <f>\|aucun] [--contre-relecture <f>]` | dev | End of development or rework: green CI required, real-world evidence at the first review, counter-review after a rework, batch back end deployed to preview (when `deploiement_preview` is configured), then review. A short-lane fix skips the preview and the counter-review |
| `verdict <v> --merger\|--a-reprendre --rapport <f> [--bloquants N] [--non-bloquants N] [--cartes-ok …] [--cartes-ko …]` | reviewer | End of review; `--merger` immediately merges the batch PRs; inconsistent verdicts refused; automatic stop at the 5th REWORK |
| `merge <v> --pr back#N` | reviewer | Guarded merge: head unchanged since the review, green CI, back before front; after a merge refused at the verdict, or in delivery review |
| `ouvrir-livraison <v>` | dev | The 4 delivery PRs, when the relay could not open them; refused while a human action is still pending |
| `passe <v> --vers <reviewer> --etape validation-prod --fichier <list>` | dev | List of visual checks in production |
| `carte-bug <v> --titre … --appli … --gravite … --description-fichier … [--version-cible <v>]` | reviewer | Bug card in the next version (or the given later one), in Not Ready |
| `carte-report <v> --titre … --appli … --gravite … --description-fichier … [--version-cible <v>]` | reviewer or dev | Point deferred to a later batch, at any step: non-blocking point from the 3rd review, old defect out of scope, leftover decided by the human |
| `reglage <v> [--ajouter … \| --fait N --preuve …]` | dev or reviewer | Deployment settings: declared during the batch, required before production checks; without an option, the list |
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
     before the verdict, and the dev only fixes the blocking points.
5. The shared review grid is [`GRILLE-REVUE.md`](GRILLE-REVUE.md), and the arbitration rules
   [`regles-arbitrage.example.md`](regles-arbitrage.example.md), to copy as `regles-arbitrage.md`.

## Requirements

Linux with user-mode systemd (cgroups v2), Python 3.11 or later (standard library only), bash, git, an authenticated
[GitHub CLI](https://cli.github.com), Claude Code for `run-lot.sh`, and an OpenClaw gateway connected to Slack for
`cycle-lot`. Both repositories follow a `develop` / `release/<version>` / `master` flow.

## Tests

```
python3 -I tests/scenario.py     # cycle-lot: full cycle, refusals, nudges, stops, gateway outage (134 checks)
bash tests/essai-run-lot.sh      # run-lot.sh end to end, on local git repositories (26 checks, ~1 min)
```

Neither calls a real service: fake `gh`, `openclaw`, `systemctl` and `claude` commands and a fake Trello API share a
JSON world.

## License

MIT, see [LICENSE](LICENSE).
