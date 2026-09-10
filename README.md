# Tool chain

A six-role agent pipeline. `run-workflow.sh` drives it end to end: one
`hermes` process per responsibility, in a fixed order, with a human approval
gate between phases. Each role runs on its own Ollama node over Tailscale.

The script never selects a model -- it selects a *role*, and the Hermes profile
of that name owns the endpoint and the model. Each agent is invoked directly,
so the phase order and the node each phase lands on are decided by
configuration, not by a model at runtime.

## Run

    ./run-workflow.sh                        # the fixed brief -- reproducible
    ./run-workflow.sh -m "build feature x"   # brief inline (quote it)
    ./run-workflow.sh -f docs/brief.md       # brief from a file
    ./run-workflow.sh -i                     # typed in, ended with Ctrl-D
    ./run-workflow.sh -h                     # usage

Prerequisites: `hermes` on PATH with the six profiles below, a git repository
with a **clean working tree**, and every node serving Ollama (see below).
`python` and `docker` are optional -- without them the script reports the
corresponding phase as unverified instead of failing.

Whichever input mode runs, the effective brief is written to `docs/brief.md`
and committed before phase 1, so an interactive run stays reproducible by
someone else: the output of an interactive run is the input to a fixed one.

Bash 3.2 compatible on purpose -- it runs unmodified under Git Bash on Windows
and `/bin/bash` on macOS.

| Variable | Default | Effect |
|---|---|---|
| `HERMES_YOLO` | `1` | `0` keeps Hermes' per-command approval prompts. A prompt inside a `-q` run has no TUI to answer it and will hang the script; the gate below is the control point instead. |
| `MAX_TURNS` | `90` | Cap on tool-calling iterations per phase, so a confused local model cannot spin. |

## Roles and nodes

Six nodes, one per assignment responsibility. Profile name == role == node, so
`hermes --profile tester` reads as one thing.

| Node | Role / profile | Responsibility | Model |
|---|---|---|---|
| node-a | `architect` | Architecture: decomposition, OpenAPI, topology, ADRs | llama3.1:8b |
| node-b | `techlead` | Tickets: scope, acceptance criteria, ordering | llama3.1:8b |
| node-c | `coder` | Implementation: multi-file repo changes | qwen2.5-coder:14b |
| node-d | `tester` | Tests + quality report, static checks, risks | qwen2.5-coder:14b |
| node-e | `docs` | README, API usage, runbook, design docs | llama3.1:8b |
| node-f | `deployer` | Dockerfile/compose, checklist, config docs | qwen2.5-coder:14b |

Each profile points at its own node's Ollama endpoint and names the model from
this table. The profile also decides the toolset: `architect`, `techlead` and
`docs` produce design and prose and need no terminal, while `coder`, `tester`
and `deployer` hold shell and git. Hermes has no per-call model or toolset
parameter -- both are fixed at invocation time -- which is why the
role-to-endpoint binding lives in the profile and the sequencing lives in the
script. Fan-out *within* a phase is Hermes' own `delegate_task`; see
[docs/orchestration-design.md](docs/orchestration-design.md).

## Ollama on each node

Ollama defaults to `127.0.0.1:11434`, which is unreachable from other machines
*and* rejects requests whose `Host` header is not localhost (HTTP 403).
On every node, ensure OLLAMA_HOST is that machine's Tailscale IP:

    Windows:
    # Quit the tray app first; it holds port 11434
    Get-Process ollama* -ErrorAction SilentlyContinue | Stop-Process

    $env:OLLAMA_HOST = "100.x.y.z:11434"
    $env:OLLAMA_KEEP_ALIVE = "30m"
    $env:OLLAMA_MAX_LOADED_MODELS = "1"

    ollama serve



    Mac:
    OLLAMA_MAX_LOADED_MODELS=1 OLLAMA_HOST=100.x.y.z:11434 OLLAMA_KEEP_ALIVE=30m ollama serve



    Linux:
    Environment="OLLAMA_HOST=100.x.y.z:11434"
    Environment="OLLAMA_KEEP_ALIVE=30m"
    Environment="OLLAMA_MAX_LOADED_MODELS=1"
    sudo systemctl daemon-reload && sudo systemctl restart ollama


Verify from another node: `curl http://<tailscale-ip>:11434/api/tags`

When testing a node from the machine it runs on, set `OLLAMA_HOST` to
`0.0.0.0` -- with a tailnet IP bound, a request that arrives as localhost is
answered with 403.

Each node must have pulled the model for its role (see the table):

    ollama pull llama3.1:8b         # node-a, node-b, node-e
    ollama pull qwen2.5-coder:14b   # node-c, node-d, node-f

With OLLAMA_MAX_LOADED_MODELS=1 each node serves exactly one model, so nothing
thrashes VRAM.

## What a run does

The script refuses to start on a dirty tree, then branches `run-<timestamp>`
from the current HEAD and commits one phase at a time onto it.

| Phase | Role | Produces |
|---|---|---|
| 0 | -- | `docs/brief.md` |
| 1 | `architect` | `artifacts/architecture.md`, `docs/openapi.yaml`, `docs/adr/` |
| 2 | `techlead` | `docs/tickets.md` |
| 3 | `coder` | the application under `app/` |
| 4 | `tester` | `app/tests/`, `docs/quality-report.md` |
| 5 | `docs` | `app/README.md`, `docs/api-usage.md`, `docs/runbook.md` |
| 6 | `deployer` | `app/Dockerfile`, `app/docker-compose.yml`, `docs/deployment-checklist.md`, `docs/configuration.md` |

Everything the pipeline generates lands under `app/`, `docs/` or `artifacts/`,
so it never collides with this README at the repo root.

Each phase is a fresh Hermes process with no memory of the previous ones. The
only handoff is `$(cat ...)` reading artifacts off disk into the next prompt,
and the brief is re-passed to every phase. The rendered prompt each phase
actually received is written to `artifacts/prompts/<n>-<role>.md` and its
transcript to `artifacts/logs/`, both committed with the phase.

### Verification, then the gate

Phases 4 and 6 have objective criteria, so the script checks them itself rather
than trusting the model's report: it re-runs `python -m pytest` in `app/` after
the tester, and `docker build` after the deployer, and prints the real exit code
next to what the phase claimed.

Then it shows the diff and waits:

| Key | Action |
|---|---|
| `a` | accept -- `git add -A` and commit `phase <n>: <role>` |
| `v` | view the full diff |
| `r` | retry -- type corrective feedback; the phase's output is reverted and it re-runs with the feedback appended to its prompt |
| `k` | abort, keep changes -- stops with the tree dirty on the run branch |
| `d` | abort and discard -- deletes uncommitted work, so it asks you to type `discard` |

New files are registered with `git add -A -N` before the diff; without that, a
phase whose entire output is new files would show an empty diff and then be
committed unreviewed.

### Comparing two runs

Because each run is its own branch off a clean base, the whole rerun comparison
is one command:

    git diff run-20260910-131200 run-20260910-154700

Runs differ even in fixed-brief mode. Where they diverge is the finding: stable
architecture and tickets with varying implementation detail is a good result; a
different number of tickets each run makes everything downstream incomparable.

## Troubleshooting

**`hermes is not on PATH`** -- checked before anything else runs, so nothing has
been branched or written yet.

**`commit or stash first`** -- a run must start from a clean base, otherwise
`git diff run-A run-B` picks up work that was never part of either run.

**The script hangs with no output** -- an approval prompt with no TUI to answer
it. Keep `HERMES_YOLO=1` (the default) so the gate is the only thing that asks
questions.

**HTTP 403 from a node** -- Ollama is bound to localhost, or the request reached
it as localhost while bound to the tailnet IP. See the section above.

**A phase produced no changes** -- the gate says so and refuses to make an empty
commit. That is normally a failed phase: retry it with `r`, or abort.

## Design notes

- [docs/orchestration-design.md](docs/orchestration-design.md) -- why the
  control flow sits in a script rather than in an agent
- [docs/workflow-script-design.md](docs/workflow-script-design.md) -- the
  driver script specification
