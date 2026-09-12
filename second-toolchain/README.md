# Tool chain 2 — opencode in a container

The same six-responsibility pipeline as [`../first-toolchain`](../first-toolchain),
rebuilt on [opencode](https://opencode.ai) instead of Hermes. Two things change:

- **Sequencing lives in opencode**, not in a driver script. Each phase is a
  slash command under `.opencode/command/`, and each role is an agent under
  `.opencode/agent/`. There is no `run-workflow.sh` equivalent — the user still
  types the phases in order, but which agent each one runs as is pinned in
  frontmatter rather than chosen by a model.
- **The agent runs in a container.** It sees the repo and nothing else, so a
  confused local model cannot reach the rest of the machine.

## Run

```sh
cp .env.example .env          # six node addresses, keys and model IDs
docker compose run --rm opencode
```

Then, inside the TUI, drive the phases in order:

```
/phase-architecture  ->  /phase-tickets  ->  /phase-implement
/phase-test          ->  /phase-docs     ->  /phase-deploy
```

Prerequisites: Docker, and the `opencode-sandbox` image (see
[Container](#container) — the Dockerfile is not written yet).

## Layout

```
opencode.json              providers, role-to-model bindings, global permissions
AGENTS.md                  project instructions, loaded into every session
docker-compose.yaml        the sandbox
.env                       node addresses, keys, model IDs — not committed
.opencode/
  agent/                   one file per role
  command/                 phase drivers, invoked as /phase-architecture etc.
docs/  src/  tests/        the work product
```

## Roles

One file per role in `.opencode/agent/`. Role names match the first tool chain,
except that `coder` is split in two so implementation tickets can be worked in
parallel.

| Agent | Responsibility | Node | Model |
|---|---|---|---|
| `architect` | Architecture: decomposition, OpenAPI, topology, ADRs | `node-a` | `llama3.1:8b` |
| `techlead` | Tickets: scope, acceptance criteria, ordering | `node-b` | `llama3.1:8b` |
| `coder-a` | Implementation: assigned tickets | `node-c` | `qwen2.5-coder:14b` |
| `coder-b` | Implementation: assigned tickets | `node-f` | `qwen2.5-coder:14b` |
| `tester` | Tests and quality report, static checks, risks | `node-d` | `qwen2.5-coder:14b` |
| `docwriter` | README, API usage, runbook, design docs | `node-e` | `llama3.1:8b` |
| `deployer` | Dockerfile/compose, checklist, config docs | `node-f` | `qwen2.5-coder:14b` |

Nodes and models line up with [`../first-toolchain`](../first-toolchain)
role-for-role, so the two chains are compared on prompting and orchestration
rather than on hardware.

The one asymmetry is the seventh role. The first chain has a single `coder` on
`node-c`; splitting it here needs a second machine with the coder model, and the
three that have it — `node-c`, `node-d`, `node-f` — are already taken. `coder-b`
therefore shares `node-f` with `deployer`. Nothing contends: phases run one at a
time, and `deployer` is the last phase while the coders run in `implement`.
`node-d` was left alone so `tester`, which runs immediately after `implement`,
never waits on a coder.

The node column is the role-to-endpoint binding from `opencode.json`; the model
each node serves comes from `.env`. See [Models](#models).

### Running on fewer machines

The six-node split is the default, not a requirement. Roles are bound to
*providers*, and several providers can point at the same machine — so to run on
two machines, give the spare nodes an address you actually have:

```sh
NODE_A_HOST=100.64.0.1:11434   # architect, and everything else on the small model
NODE_B_HOST=100.64.0.1:11434
NODE_E_HOST=100.64.0.1:11434
NODE_C_HOST=100.64.0.2:11434   # the coder model
NODE_D_HOST=100.64.0.2:11434
NODE_F_HOST=100.64.0.2:11434
```

Keep each node's `NODE_*_MODEL` matching what that machine actually serves.
Collapsing this way costs the parallelism between `coder-a` and `coder-b`, which
is the only reason the role was split.

**All six must be set to something reachable.** An unset `NODE_C_HOST` becomes
`http:///v1` and an unset `NODE_C_MODEL` registers an empty model name — neither
errors at load time, so an unused node fails at the moment a phase delegates to
it rather than at startup.

All seven are declared `mode: subagent`, so no role is reachable by the user
switching agent by hand — a phase command is the only way in.

### Phase routing

Five of the six phase commands name their agent in frontmatter, so the command
*is* that agent and no model decides where the work goes:

```yaml
---
description: Produce the system architecture
agent: architect
---
```

| Command | Runs as |
|---|---|
| `/phase-architecture` | `architect` |
| `/phase-tickets` | `techlead` |
| `/phase-implement` | primary agent → `coder-a` + `coder-b` |
| `/phase-test` | `tester` |
| `/phase-docs` | `docwriter` |
| `/phase-deploy` | `deployer` |

`/phase-implement` is the exception. `agent:` takes one name, and this phase runs
both coders in parallel — the only reason the `coder` role was split — so it
stays in the primary agent and fans out with the task tool. It is the one phase
whose routing still depends on a model's judgement.

That makes the top-level `"model"` in `opencode.json` the **primary agent's**
model: `build` and `plan` carry no model of their own and resolve from it at
session start. With five phases pinned, it drives `/phase-implement`'s fan-out
and whatever you type directly into the TUI — not the pinned roles, which take
their model from the `agent` block.

**The bodies are stubs.** Every agent and command file currently contains
`TODO:` placeholders. The wiring is proven (see
[What has been verified](#what-has-been-verified)); the prompts are not written.

## Configuration

`opencode.json` holds both halves of the setup: which endpoint and model each
role talks to, and what the agent is allowed to do. Nothing environment-specific
is committed — endpoints, keys and model IDs are all `{env:}` placeholders fed
from `.env`.

### Providers and secrets

Endpoints and keys are **not** written into `opencode.json`. The file carries
placeholders, which opencode substitutes at load time:

```json
"options": {
  "baseURL": "http://{env:NODE_A_HOST}/v1",
  "apiKey":  "{env:NODE_A_API_KEY}"
}
```

Substitution also works **mid-string**, which is what lets the scheme and the
`/v1` path stay in `opencode.json` while only the address varies per
deployment. `NODE_A_HOST` carries `ip:port` together — the port belongs with the
address because it is what distinguishes the backends (see
[Backends](#backends)).

`{env:VAR}` reads the **process environment**. opencode does *not* read `.env`
files itself — Compose does, via `env_file: .env` in `docker-compose.yaml`,
which turns the file into real container environment where `{env:}` can see it.

> A variable that is missing resolves to an empty string rather than an error.
> If a provider fails to connect, check `docker compose config` first to confirm
> the value actually reached the container.

`{file:./path}` is the other supported form, if you would rather keep a key in
its own file than in the environment.

### Models

Model IDs come from `.env` too. Substitution runs over the whole of
`opencode.json`, **including object keys**, so the entry in a provider's `models`
map can itself be a placeholder:

```json
"models": {
  "{env:NODE_A_MODEL}": { "name": "{env:NODE_A_MODEL}", "tool_call": true }
}
```

Roles are then bound to a node in the `agent` block, reusing the same variable,
so the model ID is written once per node and never repeats:

```json
"agent": {
  "architect": { "model": "node-a/{env:NODE_A_MODEL}" },
  "coder-b":   { "model": "node-f/{env:NODE_F_MODEL}" }
}
```

Which *node* a role talks to is an architecture decision and stays in
`opencode.json`; which *model* that node serves is deployment config and lives in
`.env`. To retarget a role, edit its one line; to swap models, edit `.env` only.

Set the ID exactly as the server reports it:

| Server | `NODE_*_MODEL` | Check with |
|---|---|---|
| ollama | the tag, e.g. `qwen2.5-coder:7b` | `ollama list` |
| llama.cpp | the `-a/--alias` value, else the `.gguf` filename | `curl http://$NODE_A_HOST/v1/models` |

`tool_call: true` is deliberate. A model declared on a custom
`openai-compatible` provider carries no capability metadata from the registry,
and every role here has to edit files and run commands, so the flag has to be
stated.

> **Agent frontmatter is not substituted.** `model: node-a/{env:X}` in
> `.opencode/agent/*.md` is stored verbatim — `opencode debug agent architect`
> reports `"modelID": "{env:X}"`, and the request goes out with that literal
> string. Only `opencode.json` is substituted, which is why the bindings live
> there rather than in the role files.

Each node declares exactly one model, so `NODE_*_MODEL` is the single source of
truth for what that machine serves — the same one-model-per-node discipline the
first tool chain gets from `OLLAMA_MAX_LOADED_MODELS=1`. To give one node a
second model, add another key to its `models` map and point the relevant roles
at it. Keep every declared key backed by a variable that is actually set — an
unset one collapses to `""` and registers an unusable empty-named model.

### Backends

`"npm": "@ai-sdk/openai-compatible"` is the generic OpenAI-compatible client, so
it drives **either** ollama or llama.cpp unchanged — both expose
`/v1/chat/completions`, and nothing in `opencode.json` is specific to one. Only
`.env` differs:

| | ollama | llama.cpp (`llama-server`) |
|---|---|---|
| `NODE_*_HOST` | `<tailnet-ip>:11434` | `<tailnet-ip>:8080` |
| `NODE_*_API_KEY` | ignored, leave empty | empty unless started with `--api-key` |
| `NODE_*_MODEL` | the tag (`qwen2.5-coder:7b`) | the `--alias`, else the `.gguf` filename |
| Serves | many models, loaded on demand | one model per process |

Two things to watch, neither of which the config can fix:

- **The `/v1` suffix is required.** The native ollama API is at `/api`, and the
  OpenAI-compatible one at `/v1`. It is hardcoded in `opencode.json` precisely
  so it cannot be forgotten — do not repeat it in `NODE_*_HOST`.
- **Tool calling has to actually work.** Every role here edits files, so a model
  without a tool-calling chat template is useless regardless of `tool_call: true`.
  ollama needs a model whose template declares tools; llama.cpp needs
  `--jinja` (and benefits from an explicit `--chat-template`). A model that
  narrates a tool call in prose instead of emitting one is this failing.

opencode's provider registry also carries ollama entries, but the custom-provider
form is the right one here regardless: it pins the endpoint explicitly, which is
what remote nodes over a tailnet need, and it keeps one code path whichever
backend a node runs.

### Permissions

```json
"permission": {
  "edit": "ask",
  "bash": "ask",
  "external_directory": "deny"
}
```

`external_directory` gates paths outside the working directory; the Build agent
asks by default, and this denies instead. Note what it does *not* do: inside the
container the working directory is `/workspace`, so this blocks nothing within
the repo. That is intentional — the repo is the agent's workspace, and the
container boundary is what keeps the rest of the machine out of reach.

## Container

`docker-compose.yaml` runs opencode with the repo as its only mount:

```yaml
volumes:
  - .:/workspace
  - ./.opencode:/workspace/.opencode:ro
```

The host path is relative on purpose. Compose resolves relative bind mounts
against **the directory holding the compose file**, not the shell's working
directory, so `docker compose -f /any/path/docker-compose.yaml up` still mounts
this repo.

`.opencode` is mounted a second time read-only, on top of the writable repo
mount, so the agent definitions and phase commands cannot be rewritten by the
agent running under them.

`user: "1000:1000"` runs the agent unprivileged. Two named volumes
(`opencode-config`, `opencode-state`) keep opencode's own config and session
history out of the repo and persistent across `--rm` runs.

There is **no `extra_hosts` block and no name resolution to arrange.** Providers
address the nodes by raw tailnet IP, so the container needs nothing mapped:

```
NODE_A_HOST=100.64.0.1:11434       # .env
"baseURL": "http://{env:NODE_A_HOST}/v1"   # opencode.json
```

Mapping hostnames with `extra_hosts` would describe each node twice — once as
an address for Compose, once as a hostname inside the base URL — with nothing
keeping the two in step. With MagicDNS not in use and the tailnet IP stable, the
hostname earns nothing. Addressing by IP also keeps the compose file free of
interpolation, so `.env` reaches opencode by exactly one path: `env_file:`.

Compose loads `.env` from the directory holding the compose file — the same
relative-path rule as the bind mounts above — and passes it into the container
verbatim. Note that `env_file:` does **not** inherit the host shell, so
`NODE_A_HOST=... docker compose run` will not override the file; edit `.env`.

All six nodes (`node-a` through `node-f`) are configured, matching the first
tool chain. To run on fewer machines, point several `NODE_*_HOST` variables at
the same address — see [Running on fewer machines](#running-on-fewer-machines).

## What has been verified

Checked against opencode `1.18.29` with `opencode debug config` and
`opencode debug agent build`, not assumed from documentation:

| Claim | Result |
|---|---|
| `external_directory` is a real permission key | Present in the binary; appears in the resolved rule set |
| `"external_directory": "deny"` overrides the built-in `ask` | Confirmed — later rules win, and the user config merges last |
| Both `opencode.json` and `.opencode/opencode.json` are loaded | Confirmed; project config overrides global |
| `.opencode/agent/` and `.opencode/command/` are read | All 7 agents and 6 commands register |
| The plural `agents/` and `commands/` are *also* read | Confirmed — neither spelling is silently ignored |
| `{env:VAR}` substitution | Resolves from process environment only |
| `{env:VAR}` inside a `models` **key** | Confirmed — keys are substituted, not just values |
| `{env:VAR}` in `.opencode/agent/*.md` frontmatter | **No** — stored verbatim; `modelID` stays `{env:VAR}` |
| `{env:VAR}` in `.opencode/command/*.md` frontmatter | **No** — same as agent files; only `opencode.json` is substituted |
| `agent:` in command frontmatter pins the role | Confirmed — all 5 appear as `agent=<role>` in the resolved `command` block |
| Primary agents (`build`, `plan`) carry no model | Confirmed — they resolve from the top-level `model` at session start |
| `agent.<role>.model` in `opencode.json` overrides the role file | Confirmed via `opencode debug agent <role>` |
| An unset variable | Resolves to `""`, so a model key becomes `""` rather than erroring |
| `{file:./path}` substitution | Resolves from file contents |
| `{env:VAR}` mid-string | Confirmed — `http://{env:NODE_A_HOST}/v1` resolves |
| `env_file:` passes `.env` into the container | Confirmed via `docker compose config`; shell values do not override it |
| A `.env` file alone feeds `{env:}` | **No** — needs `env_file:` in Compose |
| Relative bind mount resolves to this directory | Confirmed via `docker compose config` |

Two carve-outs survive `external_directory: deny`, both re-added by opencode
after user config and not disableable from config: its own `tool-output` and
temp directories. Inside the container those land in the `opencode-state`
volume, not on the host filesystem.

`opencode agent create` writes to the **plural** `.opencode/agents/`. Since both
spellings load, using that command will quietly produce a second directory
alongside the singular one — harmless, but worth knowing before the layout
drifts.

## Not done yet

- **No Dockerfile.** `docker-compose.yaml` references an `opencode-sandbox`
  image that has to be built first — opencode on a base image, a `1000:1000`
  user, and whatever toolchain the `coder`/`tester`/`deployer` roles need.
- **Agent and command bodies are `TODO` stubs.**
- **`NODE_*_HOST` addresses are examples.** `.env.example` ships
  `100.64.0.1` through `100.64.0.6`; replace them with `tailscale ip -4` output
  from each machine.
- **No model has been pulled by this repo.** Each node needs its role's model
  present (`ollama pull llama3.1:8b` on a/b/e, `qwen2.5-coder:14b` on c/d/f),
  exactly as in the first tool chain.
- **`AGENTS.md`** has a `TODO` conventions section.

## Troubleshooting

**A provider gets an empty `baseURL` or `apiKey`.** The variable never reached
the container. `docker compose config` prints the resolved `environment:` block
— if the value is `""` there, the problem is `.env`, not opencode.

**A provider cannot connect.** There is no name resolution in the path any more,
so it is the address or the tailnet. `docker compose config` shows what
`NODE_A_HOST` reached the container as; `opencode debug config` shows the
assembled `baseURL`. If both look right, test reachability directly:
`curl http://$NODE_A_HOST/v1/models`.

**The model 404s, or the agent picks the wrong one.** `opencode debug agent
<role>` prints the resolved `providerID`/`modelID`. If `modelID` still reads
`{env:...}`, the binding was put in the role's frontmatter, where substitution
does not run — move it to the `agent` block in `opencode.json`. If it is empty,
the variable is unset. If it is a plausible-looking ID that the server rejects,
compare it against `curl http://$NODE_A_HOST/v1/models`.

**An agent or command does not appear.** Run `opencode debug config` and look at
the `agent` / `command` keys. Missing frontmatter `description` is the usual
cause.

**Checking what the agent is actually allowed to do.**
`opencode debug agent build` prints the fully resolved permission list in
evaluation order. Later entries override earlier ones.

**`.opencode/.gitignore` appeared on its own.** opencode writes it. Expected.

## Design notes

The two tool chains differ in where the sequencing lives. The first puts it in
`run-workflow.sh` — an explicit, inspectable order with a human gate between
phases, and the model never chooses what runs next. The second puts it in
opencode's own command and agent files.

The gap is narrower than it first looks. Pinning `agent:` in command frontmatter
takes role selection away from the model, so five of six phases route as
deterministically as a script would; what opencode still leaves to the model is
*fan-out* inside `/phase-implement`, and the ordering of phases, which the user
supplies by typing them. The first chain's remaining edge is that the order is
enforced rather than conventional.

That trade is the point of building both: the script is more reproducible, the
opencode version is less to maintain and gets a real sandbox boundary almost
for free. Neither property is available in the other without rebuilding it.

## Security note

`.env` sits inside the `.:/workspace` mount, so the agent can read the keys with
`cat .env`. opencode's built-in defaults gate this — `read` on `*.env` and
`*.env.*` resolves to `ask`, and the config here does not override `read` — so
it is an approval prompt, not a wall. To put the keys genuinely out of reach,
pass them through `environment:` in Compose from a file kept outside the
workspace instead.
