# Local multi-LLM coding workflow evaluation

Two candidate tool chains for running a multi-agent coding workflow against
local model endpoints, built so they can be compared rather than argued about.
Both cover the same six responsibilities, architecture through deployment
validation, and both route roles to separate local endpoints by configuration.

They differ in one decision: where the sequencing lives. That difference drives
almost everything else, so each chain is a complete implementation rather than a
sketch.

| | [`first-toolchain/`](first-toolchain) | [`second-toolchain/`](second-toolchain) |
|---|---|---|
| Agent | Hermes | opencode |
| Sequencing | `run-workflow.sh`, a driver script | opencode slash commands |
| Role to endpoint | one Hermes profile per node | one provider per node in `opencode.json` |
| Control point | human gate between phases | ask before edit, ask before run |
| Isolation | runs on the host | runs in a container |
| Status | runs end to end | wiring verified, role prompts unwritten |

## Shared prerequisites

Both chains talk to the same fleet, so set this up once.

Six machines reachable over a tailnet, each serving a model on an
OpenAI-compatible endpoint. The first chain expects ollama. The second accepts
ollama or llama.cpp.

Bind the server to the tailnet address rather than localhost, and pull the model
each node is responsible for. The first chain's README covers the ollama
specifics, including the 403 that localhost binding causes.

Fewer than six machines works. Point several roles at the same endpoint and
accept the loss of parallelism.

## First tool chain

Hermes, one profile per node, talking straight to each node's endpoint with no
gateway in between. `run-workflow.sh` runs the six phases in a fixed order.

The script never picks a model. It picks a role, and the Hermes profile of that
name owns the endpoint, the model and the toolset. Design and prose roles get no
terminal. Implementation, testing and deployment roles hold shell and git.

Each phase is a fresh Hermes process with no memory of the previous one.
Handoff happens through artifacts on disk, read into the next prompt, with the
brief re-passed every time. The prompt each phase received and its transcript
are committed alongside its output.

A run refuses to start on a dirty tree, branches `run-<timestamp>`, and commits
one phase at a time. Comparing two runs is one `git diff` between branches.

Phases with objective criteria are checked rather than trusted. The script
re-runs the test suite after the testing phase and a container build after the
deployment phase, then prints the real exit code next to what the phase claimed.
Then it shows the diff and waits, offering accept, view, retry with corrective
feedback, or abort.

See [`first-toolchain/README.md`](first-toolchain/README.md).

## Second tool chain

opencode in a container. Each phase is a slash command, each role is an agent
file, and there is no driver script.

Five of the six phase commands name their agent in frontmatter, so the command
is that agent and no model chooses where the work goes. The implementation phase
is the exception, because it runs two coding workers in parallel and fans out
from the primary agent.

Endpoints, keys and model IDs are placeholders in `opencode.json` filled from
`.env`. Nothing environment-specific is committed.

The container is the isolation boundary. The agent sees the repo and nothing
else, so a confused local model cannot reach the rest of the machine. Role
definitions are mounted read-only on top of the writable repo, so the agent
cannot rewrite the rules it runs under.

See [`second-toolchain/README.md`](second-toolchain/README.md).

## How they compare

Setup complexity favours the first chain today. It needs Hermes, six profiles
and a clean git tree, and the profile script writes the endpoint binding from
`.env`. The second chain needs Docker and a sandbox image build on top of the
published opencode image, which adds a build step the first chain does not have.

Multi-endpoint support is equivalent. Both bind each role to its own endpoint by
configuration, and both collapse onto fewer machines by pointing several roles
at one address. Neither needs a router or a gateway.

Predictability differs in kind rather than degree. The first chain batches
control into a gate between phases, where a whole phase is reviewed as a diff
and can be retried with feedback. The second chain spreads control across every
action, asking before each edit and each command. The first is better for
reviewing a coherent unit of work. The second stops a bad action before it
happens.

Reproducibility currently favours the first chain, which enforces phase order,
commits per phase, and makes a rerun comparison a single diff between two run
branches. The second chain relies on the user typing the phases in order, and
has no equivalent commit discipline yet.

Context management is explicit in both. The first chain starts every phase in a
fresh process and hands off only through files on disk, so nothing is lost
silently because nothing is carried implicitly. The second chain gets the same
property from subagents, each with its own context, reading the repo as it
stands.

Failure modes worth watching in both are tool calling and test execution. A
local model that describes a tool call in prose instead of emitting one breaks
any agent workflow regardless of configuration. The first chain catches a
failing phase at the gate, with a verified exit code next to the claim. The
second chain has no equivalent automatic check yet.

## Recommendation

Not settled. The first chain is further along and currently stronger on
reproducibility and verification. The second has the better isolation story and
less code to maintain.

What decides it is whether the second chain's role prompts, once written,
produce output comparable to the first chain's. Until that run happens, a
recommendation would be a preference rather than a finding.

## Status

The first chain runs end to end.

The second chain has its configuration and routing verified against a pinned
opencode version, listed in its README. The role and command bodies are still
`TODO` stubs, and the sandbox image has not been built.

Deliverables still outstanding are the synopsis and the review of another
group's work.

## Layout

```
first-toolchain/     Hermes, driven by run-workflow.sh
second-toolchain/    opencode, driven by slash commands in a container
```

Each directory is self-contained, with its own README, configuration and setup
guide.
