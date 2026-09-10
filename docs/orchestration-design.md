# Orchestration design: what is automated and what is not

Reference note for the synopsis. Records how the toolchain is driven end to end,
and why the control flow sits where it does.

## Summary

The pipeline is launched with a single command:

    ./run-workflow.sh

The script invokes Hermes six times in sequence -- one per responsibility. It is
not six commands typed by hand. But the sequencing is decided by a shell script
rather than by a model, and each phase stops for a human approval gate.

## What is automatic, and what is not

| Layer | Who decides | Automatic |
|---|---|---|
| Phase order (architecture -> tickets -> implementation -> testing -> docs -> deployment) | `run-workflow.sh` | Scripted, not model-driven |
| Which node each phase runs on | `--profile <role>` resolved through that profile's own `config.yaml` | Yes |
| Context passed between phases | `$(cat docs/tickets.md)` and friends, written into the prompt | Explicit, hardcoded |
| Approval between phases | The operator, at the `read -rp "Continue? [y/N]"` gate | No -- six manual confirmations |
| Subagent fan-out *within* the implementation phase | Hermes `delegate_task` | Yes, fully |

The orchestrator in this design is therefore **the shell script**, not an agent.
Hermes is a per-phase worker that is itself agentic *inside* its phase. This is
the two-tier architecture: CLI invocation binds role to endpoint, `delegate_task`
provides parallelism within a role.

There is no gateway between Hermes and the nodes anymore. Each of the six
profiles (`architect`, `techlead`, `coder`, `tester`, `docs`, `deployer`) has its
own `providers.<role>.base_url` pointing straight at that node's Ollama
endpoint (`http://<node-ip>:11434/v1`), written by
`bin/setup-hermes-profiles.sh` from the `.env` node IPs. `--profile <role>`
picks the node the same way `-m <model>` used to, just without a router in the
middle to fail or add a hop.

## Why the control flow sits one level up

Two constraints in Hermes force it, for the `delegate_task` fan-out
specifically:

1. **`delegation.model` is global.** A single Hermes process cannot route
   subagent A to `architect` and subagent B to `tester` via `delegate_task`;
   there is no per-call model parameter for that primitive. Role-to-endpoint
   binding must therefore happen at invocation time, which is what
   `--profile architect` versus `--profile coder` achieves -- each profile's own
   `config.yaml` names its node, so the node is selected by configuration
   alone and nothing is rewired between runs.

2. **`delegate_task` has no `toolsets` parameter.** Subagents inherit the
   parent's enabled toolsets and the model cannot widen them per call. Separate
   invocations are what allow the `architect` profile to run with no terminal
   access while `coder` holds shell and git. An architect that cannot execute
   shell commands is a meaningful safety property and concrete evidence for the
   predictability requirement.

### The kanban board is a third option, not covered by either constraint

`hermes kanban` routes at the *task* level instead of the process level, and
neither constraint above applies to it:

- `kanban create --assignee <profile>`, `kanban assign <task> <profile>`, and
  `kanban set-model <task> <model> --provider <provider>` bind one task to one
  profile/node, or override its model/provider outright, independent of
  `delegation.model`.
- `kanban swarm --worker coder:... --worker tester:... --worker deployer:...
  --verifier <profile> --synthesizer <profile>` creates a parallel-workers ->
  verifier -> synthesizer graph in one call -- a built-in replacement for both
  the `worker` load-balanced pool LiteLLM used to provide and for hand-rolled
  fan-out via `delegate_task`.
- Tasks are durable (SQLite-backed), claimed atomically, can depend on each
  other (`kanban link`), and carry review states (`request-review`,
  `request-changes`) -- which is most of what the six-phase gate in
  `run-workflow.sh` does by hand, as a re-runnable dispatcher loop instead of a
  bash script.

This repo's driver still uses the shell-script design in
[workflow-script-design.md](workflow-script-design.md) because that design
predates discovering `kanban`'s task-level routing and is further along.
Re-platforming the six-phase pipeline onto `kanban` (one task per phase,
linked in sequence, review gates instead of `read -rp`) is a plausible
follow-up, not something this document assumes.

## The approval gates are deliberate

`-q` runs Hermes non-interactively, which a script requires, but it also means
Hermes acts without asking. The `gate` function is the control mechanism in its
place: every phase ends with a diff review and an explicit commit. This satisfies
"plan and diffs for review before execution" and yields one clean commit per
phase for the reproducibility requirement.

For the live demonstration, run at least one phase interactively
(`hermes --profile coder`, without `-q`) so a real command-approval prompt can be
captured.

## Context handoff is file-backed by design

Each invocation is a fresh agent with no knowledge of prior phases. The
`$(cat ...)` substitutions in the driver script are the entire handoff mechanism.
Anything not passed in is lost.

This is the answer to the question of how the toolchain avoids silent context
loss: handoffs are artifacts on disk, reviewable in git, and identical on every
rerun. Nothing depends on a model remembering something. As the repository grows,
each phase reads only the artifacts it needs rather than accumulating the whole
history.

## Consequence for the six-role configuration

The original driver script was written against a four-name routing config, so it
reused `architect` for the tech-lead and documentation phases:

    run_phase architect architect tickets.md        # tech lead
    run_phase docs      architect documentation.md  # documentation

With `techlead`, `docs` and `deployer` now bound to their own profiles/nodes via
`bin/setup-hermes-profiles.sh`, those calls should become
`run_phase techlead --profile techlead` and `run_phase docs --profile docs`.
Otherwise three of the six nodes never receive traffic and the multi-endpoint
requirement is only half demonstrated.
