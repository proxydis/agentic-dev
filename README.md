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
| 7 | Review | reviewer | Code review, tests, Playwright journeys on the deployed batch; verdict MERGE or REWORK |
| 8 | Rework | dev | Every point, blocking or not, on the same PRs |
| 9 | 7 ↔ 8 | | Automatic until MERGE; stops at the 3rd REWORK |
| 10 | Batch merge | reviewer | `cycle-lot merge` of each PR into the release (squash, back first) |
| 11 | Delivery | dev | `cycle-lot ouvrir-livraison`: 4 PRs, release into `develop` and `master`, back and front |
| 12 | Delivery review | reviewer | Content limited to the reviewed batch, then merge of the 4 PRs |
| 13 | Production | relay, then dev | CI of `develop` and `master` (deployment included), then the list of visual checks to run in production |
| 14 | Production checks | reviewer | Playwright on production, one Trello card per defect, in the next version, in Not Ready |

Trello follows the cycle: Work in progress at start, Waiting for review as soon as a pass is pushed to the batch PR,
Under review when the review starts, Finished or back to Work in progress at the verdict. A validated card never moves
again.

**Stops.** The cycle stops on a blocking question, when the human has to act (environment variable, token,
account…), and at the 3rd REWORK verdict. Questions and required human actions are raised at the start of the batch,
not halfway through. On a stop, the relay posts a notice in the thread naming the agent to mention; the human answers
by mentioning it, and that agent resumes the cycle (`cycle-lot reprise`).

## Why a relay

Two agents that wait for each other end up deadlocked. It only takes each of them writing a script that waits for the
other ("I wait until the dev's jobs are done", "I wait until the reviewer merges") for everything to stall, silently.
Here, no agent ever waits:

- an agent ends its step with a `cycle-lot` command, which checks the transition, updates the batch state and
  schedules the next agent's wake-up;
- the relay (`cycle-lot veille`, every 2 minutes, under systemd) performs the wake-ups and owns every wait, which
  only depends on GitHub;
- an agent that stops showing signs of life is nudged twice, then the human is alerted in the thread.

The wake-up goes through the OpenClaw gateway `agent` RPC, into the agent's session for the batch's Slack thread, and
the agent's reply is posted there. It runs from the systemd service, not from an agent's exec: the gateway refuses to
let an agent wake another session itself.

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
| `passe <v> --vers <reviewer> --message …` | dev | End of development or rework: green CI required, batch back end deployed to preview (when `deploiement_preview` is configured), then review |
| `verdict <v> --merger\|--a-reprendre --rapport <f> [--cartes-ok …] [--cartes-ko …]` | reviewer | End of review; automatic stop at the 3rd REWORK |
| `merge <v> --pr back#N` | reviewer | Guarded merge: head unchanged since the review, green CI, back before front |
| `ouvrir-livraison <v>` | dev | The 4 delivery PRs; refused while a human action is still pending |
| `passe <v> --vers <reviewer> --etape validation-prod --fichier <list>` | dev | List of visual checks in production |
| `carte-bug <v> --titre … --appli … --gravite … --description-fichier …` | reviewer | Bug card in the next version, in Not Ready |
| `fin <v> --rapport <f>` | reviewer | Batch delivered and validated |
| `arret`, `reprise`, `intervention`, `programmer`, `reveiller` | | Stop and resume, human actions, deferred start, manual wake-up |
| `etat [<v>] [--json]` | anyone | Read only |
| `veille` | relay | One pass of the timer |

A batch's state lives in `cycles/<version>/etat.json`, next to its log `journal.log`. The relay's heartbeat is
`cycles/.veille.json` (last pass, errors): a dashboard can read it to show batches and the runs being waited for.

**Installation.**

1. Copy [`cycle-lot.example.json`](cycle-lot.example.json) to `cycle-lot.json` and fill it in: the OpenClaw ids of
   both agents and of the account that posts the relay's notices, the human (name, Slack id), the GitHub repositories
   and required CI jobs, production and preview URLs, Trello lists and labels. Trello keys are read from the
   environment (`TRELLO_API_KEY`, `TRELLO_TOKEN`) or from the OpenClaw config.
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
     otherwise the relay thinks the agent is idle and nudges it.
5. The shared review grid is [`GRILLE-REVUE.md`](GRILLE-REVUE.md), and the arbitration rules
   [`regles-arbitrage.example.md`](regles-arbitrage.example.md), to copy as `regles-arbitrage.md`.

## Requirements

Linux with user-mode systemd (cgroups v2), Python 3.11 or later (standard library only), bash, git, an authenticated
[GitHub CLI](https://cli.github.com), Claude Code for `run-lot.sh`, and an OpenClaw gateway connected to Slack for
`cycle-lot`. Both repositories follow a `develop` / `release/<version>` / `master` flow.

## Tests

```
python3 -I tests/scenario.py     # cycle-lot: full cycle, refusals, nudges, stops, gateway outage (59 checks)
bash tests/essai-run-lot.sh      # run-lot.sh end to end, on local git repositories (22 checks, ~1 min)
```

Neither calls a real service: fake `gh`, `openclaw`, `systemctl` and `claude` commands and a fake Trello API share a
JSON world.
