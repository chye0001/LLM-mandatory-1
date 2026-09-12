---
description: Implement the open tickets
---

# Phase: Implement

TODO: what this phase does, and how tickets are split between the two coders.

The one phase that is **not** pinned to an agent. `agent:` takes a single name,
and this phase runs `coder-a` and `coder-b` in parallel, so it stays in the
primary agent and fans out with the task tool. Splitting the `coder` role is the
only reason that parallelism exists — pinning one coder here would discard it.

Delegate to both `coder-a` and `coder-b`, one ticket set each.

Arguments: $ARGUMENTS
