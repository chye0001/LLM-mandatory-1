# Driver script design: `run-workflow.sh`

Specification for the script that drives the six-role pipeline. Companion to
[orchestration-design.md](orchestration-design.md), which covers *why* control
flow sits in a script rather than in an agent.

Status: agreed, not yet implemented.

## One script, four input modes

    ./run-workflow.sh                        # fixed brief -- for rerun comparison
    ./run-workflow.sh -m "build feature x"   # brief inline
    ./run-workflow.sh -f docs/brief.md       # brief from a file
    ./run-workflow.sh -i                     # multi-line, terminated by Ctrl-D

The fixed brief is a constant at the top of the script, so it is committed,
diffable, and identical on every run. That is what makes the reproducibility
comparison in the checklist meaningful.

`-i` and `-f` exist because `-m` cannot carry an app-sized brief, and because a
natural-language brief typed at the shell hits characters the shell consumes
before the script ever sees them: an apostrophe in "it's" leaves the shell
waiting for a closing quote, `!` triggers history expansion, and `*`, `$`, `(`,
`)`, `&`, `;` glob, expand, or fail to parse. No script can recover from that --
it happens one layer up. Quoting `-m "..."` is required; `-i` sidesteps quoting
entirely.

### Phase 0: capture the brief

Whichever mode runs, the effective brief is written to `docs/brief.md` and
committed before the architect starts. An interactive run is therefore still
reproducible by a third party: the *output* of an interactive run is the *input*
to a fixed one.

This separates the **what** (`docs/brief.md`) from the **how**
(`run-workflow.sh`), both committed, both diffable.

## What flows between phases

Every phase is a fresh Hermes process with no memory of the previous ones. The
only connection between them is `$(cat ...)` reading artifacts off disk.

    brief ──▶ [1 architect]  docs/openapi.yaml, docs/adr/, artifacts/architecture.md
                    │
                    ├─ architecture.md + openapi.yaml
                    ▼
              [2 techlead]   docs/tickets.md
                    │
                    ├─ tickets.md + openapi.yaml
                    ▼
              [3 coder]      implementation -- fans out to the worker pool
                    ▼
              [4 tester]     docs/quality-report.md
                    ▼
              [5 docs]       README.md, docs/api-usage.md, docs/runbook.md
                    ▼
              [6 deployer]   Dockerfile, compose, deployment checklist, config docs

Two decisions on top of this:

- **The brief is passed to every phase**, not only the architect. By phase 3 the
  coder otherwise knows about tickets but not about what was actually asked for,
  and small local models drift.
- **The architect restates its understanding** at the top of `architecture.md`,
  so the first approval gate catches a misread brief before five further phases
  build on it. This is the cheapest available correction point.

## The approval gate

### Bug in the original

The guide's gate shows `git diff --stat`, which is blind to untracked files, then
commits with `git add -A`. The architecture phase's entire output is *new* files,
so the gate would display a near-empty diff and commit work that was never
reviewed. Verified:

    $ git --no-pager diff --stat          # what the gate showed
     README.md | 2 +-

    $ git --no-pager status --short       # what actually changed
     M README.md
    ?? docs/

Fix: run `git add -A -N` first, which registers new files as empty so the diff
includes them. All three files then appear.

### Four outcomes, not two

A phase fails review for different reasons, and `y`/`n` is too blunt:

| Key | Action |
|---|---|
| `a` | accept -- `git add -A` and commit `phase: <name>` |
| `r` | retry -- prompt for corrective feedback, re-run the same phase with it appended |
| `k` | abort, keep changes -- exit with the working tree dirty for inspection |
| `d` | abort, discard -- `git checkout -- . && git clean -fd`, then exit |

`r` is the one the guide omits and the one that matters most. Local models fumble
a phase regularly; without retry the only recourse is re-running from phase 1,
which -- the models being non-deterministic -- yields different phases 1-3 as
well. The run would never converge.

`d` permanently deletes untracked files via `git clean -fd`, so it requires
typing a word rather than a single keystroke.

Implementing `r` means `run_phase` and `gate` loop together, so a phase can be
re-invoked with its original prompt plus the operator's feedback.

## Verify before asking

Two phases have objective pass/fail criteria, so the script checks them itself
and shows the result alongside the diff:

- **Phase 4 (testing):** run `pytest` and capture the exit code.
- **Phase 6 (deployment):** run `docker build` and capture the result.

The phase prompts already instruct the agent not to claim success without
running these, but that trusts the model's self-report. Checking directly is
stronger, and "the toolchain verifies rather than trusts the model's report" is
direct evidence for the predictability requirement.

## Run isolation

The script refuses to start on a dirty working tree and creates a branch
`run-<timestamp>` from a clean base. Comparing two runs is then
`git diff run-A run-B` rather than manual bookkeeping, and "run twice from a
clean branch" becomes a property of the tool rather than a procedure to remember.

## Expectations for the rerun comparison

Runs will differ even in fixed mode; the checklist says as much, and divergence
is a finding to document rather than a failure. Divergence has three sources at
once:

1. sampling randomness
2. `least-busy` routing sending tickets to different nodes
3. genuine model non-determinism

Pinning `temperature: 0` in `litellm_params` removes (1) and makes the others
legible. Worth running as a deliberate experiment rather than adopting as a
default.

The useful question is not whether outputs match but *where* they diverge. Stable
architecture and tickets with varying implementation detail is a strong result
about the toolchain. A different number of tickets each run makes everything
downstream incomparable, and is worth discovering early.

## Rejected alternatives

**Three files** (`workflow-lib.sh` + a fixed entry point + an interactive one).
The library existed only to stop two entry points duplicating the six phase
prompts -- circular, since a single entry point creates no duplication. One file
also matches the checklist, which names `run-workflow.sh` and asks for every
phase prompt to be committed in it, and avoids a `source "$(dirname "$0")/..."`
path that is one more thing to break under Git Bash.

**Interactive input without capture.** A brief typed at runtime exists nowhere in
the repository, which quietly breaks reproducibility by a third party. Writing it
to `docs/brief.md` costs nothing and removes the objection.

**An agent orchestrator that shells out to `hermes --profile ...` instead of a
script.** Rejected for reasons recorded in
[orchestration-design.md](orchestration-design.md).

## Constraints

Bash 3.2 compatible -- no associative arrays or other bash 4+ features -- so the
script runs unmodified if a teammate drives the pipeline from macOS.
