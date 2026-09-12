# Tool chain 2: opencode in a container

The same six-responsibility pipeline as [`../first-toolchain`](../first-toolchain),
rebuilt on [opencode](https://opencode.ai) instead of Hermes. Two things differ.

Sequencing lives in opencode rather than in a driver script. Each phase is a
slash command under `.opencode/command/`, and each role is an agent under
`.opencode/agent/`. There is no `run-workflow.sh` equivalent.

The agent runs in a container. It sees the repo and nothing else, so a confused
local model cannot reach the rest of the machine.

---

## Part 1: running it

### Requirements

- Docker. The sandbox image builds on first run, see
  [Sandbox image](#sandbox-image).
- At least one machine running an OpenAI-compatible model server and reachable
  from this one. ollama and llama.cpp both work. See [Backends](#backends).

### Setup

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

## .env
Copy the example environment file.

```sh
cp .env.example .env
```

Edit `.env`. It defines six nodes, `node-a` through `node-f`, and each node has
three variables.

| Variable | What to put in it |
|---|---|
| `NODE_A_HOST` | Address and port of the server, such as `100.64.0.1:11434`. No scheme, no path. |
| `NODE_A_API_KEY` | Leave empty unless the server requires a key. |
| `NODE_A_MODEL` | The model ID that server reports, copied exactly. |

`opencode.json` wraps each host as `http://<host>/v1`, so do not write `http://`
or `/v1` into the variable.

Check that a node answers before starting the container.

```sh
curl http://100.64.0.1:11434/v1/models
```

Then start it. The first run builds the sandbox image, which takes a few
minutes. Later runs reuse it.

```sh
docker compose run --rm opencode
```

The image installs `nodejs npm python3` by default. If the project uses another
language, set `LANG_PACKAGES` in `.env` and rebuild with
`docker compose build`.

### Running a workflow

Inside the TUI, run the phases in order.

```
/phase-architecture
/phase-tickets
/phase-implement
/phase-test
/phase-docs
/phase-deploy
```

Each command runs as its own role on its own node. Nothing enforces the
ordering, so you type the phases yourself.

### Running on fewer machines

Six nodes is the default, not a requirement. Roles bind to providers, and
several providers can address one machine. To run on two machines, give the
spare nodes an address you have.

```sh
NODE_A_HOST=100.64.0.1:11434
NODE_B_HOST=100.64.0.1:11434
NODE_E_HOST=100.64.0.1:11434
NODE_C_HOST=100.64.0.2:11434
NODE_D_HOST=100.64.0.2:11434
NODE_F_HOST=100.64.0.2:11434
```

Set each `NODE_*_MODEL` to the model that machine actually serves. Collapsing
this way costs the parallelism between `coder-a` and `coder-b`, which is the
only reason that role was split.

Fill in all six nodes. An unset `NODE_C_HOST` resolves to `http:///v1`, and an
unset `NODE_C_MODEL` registers a model with an empty name. Neither one errors
when the config loads, so the failure appears when a phase first calls that
node.

### Backends

`@ai-sdk/openai-compatible` drives either backend without changes, because both
expose `/v1/chat/completions`. Only `.env` differs.

| | ollama | llama.cpp (`llama-server`) |
|---|---|---|
| `NODE_*_HOST` | `<ip>:11434` | `<ip>:8080` |
| `NODE_*_API_KEY` | ignored, leave empty | empty unless started with `--api-key` |
| `NODE_*_MODEL` | the tag, from `ollama list` | the `--alias`, otherwise the `.gguf` filename |
| Serves | many models, loaded on demand | one model per process |

Two things to watch, neither of which the config can fix.

The `/v1` suffix is required. ollama's native API is at `/api` and the
OpenAI-compatible one is at `/v1`. `opencode.json` hardcodes the suffix, which is
why `NODE_*_HOST` must not repeat it.

Tool calling has to work on the model itself. Every role edits files, so a model
without a tool-calling chat template is useless here whatever the config says.
ollama needs a model whose template declares tools, and llama.cpp needs
`--jinja`. A model that describes a tool call in prose instead of emitting one
is failing this.

### Troubleshooting

A provider gets an empty `baseURL` or `apiKey`. The variable never reached the
container. Run `docker compose config` and read the resolved `environment:`
block. If the value is empty there, the problem is in `.env`, not in opencode.

A provider cannot connect. No name resolution happens anywhere in the path, so
the cause is the address or the tailnet. `opencode debug config` shows the
assembled `baseURL`. If it looks right, test the server directly with
`curl http://<host>/v1/models`.

The model returns 404, or a role uses the wrong one. Run
`opencode debug agent <role>`, which prints the resolved `providerID` and
`modelID`. A `modelID` still reading `{env:...}` means the binding sits in the
role's frontmatter, where substitution does not run, so move it to the `agent`
block in `opencode.json`. An empty `modelID` means the variable is unset. An ID
the server rejects should be compared against `curl http://<host>/v1/models`.

An agent or command does not appear. Run `opencode debug config` and look at the
`agent` and `command` keys. A missing `description` in the frontmatter is the
usual cause.

`.opencode/.gitignore` appeared on its own. opencode writes it, and that is
expected.

---

## Part 2: how the setup works

### Layout

```
opencode.json              providers, role-to-model bindings, permissions
AGENTS.md                  project instructions, loaded into every session
Dockerfile                 the sandbox image
docker-compose.yaml        the sandbox
.env                       node addresses, keys, model IDs. Not committed
.opencode/
  agent/                   one file per role
  command/                 phase drivers, invoked as /phase-architecture
docs/  src/  tests/        the work product
```

### Roles

One file per role in `.opencode/agent/`. Role names match the first tool chain,
except that `coder` is split in two so implementation tickets can run in
parallel.

| Agent | Responsibility |
|---|---|
| `architect` | Architecture: decomposition, OpenAPI, topology, ADRs |
| `techlead` | Tickets: scope, acceptance criteria, ordering |
| `coder-a` | Implementation: assigned tickets |
| `coder-b` | Implementation: assigned tickets |
| `tester` | Tests and quality report, static checks, risks |
| `docwriter` | README, API usage, runbook, design docs |
| `deployer` | Dockerfile and compose, checklist, config docs |

Each role binds to one provider in the `agent` block of `opencode.json`, and the
model that provider serves comes from `.env`. See [Models](#models) for the
binding, and `opencode.json` for the mapping in force.

Roles can share a node. With more roles than machines some sharing is required,
and it costs nothing as long as the roles that share never run in the same
phase. `coder-a` and `coder-b` are the pair to keep apart, because running them
on one node removes the parallelism that splitting the role provides.

All seven roles declare `mode: subagent`, so a phase command is the only way to
reach them. Every agent and command body is still a `TODO` stub. The wiring is
proven, see [What has been verified](#what-has-been-verified), but the prompts
are not written.

### Phase routing

Five of the six phase commands name their agent in frontmatter, so the command
is that agent and no model decides where the work goes.

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
| `/phase-implement` | the primary agent, which calls `coder-a` and `coder-b` |
| `/phase-test` | `tester` |
| `/phase-docs` | `docwriter` |
| `/phase-deploy` | `deployer` |

`/phase-implement` is the exception. `agent:` takes one name, and this phase runs
both coders in parallel, so it stays in the primary agent and fans out with the
task tool. Its routing is the only routing that still depends on a model's
judgement.

This is what the top-level `"model"` in `opencode.json` is for. The primary
agents, `build` and `plan`, carry no model of their own and resolve it from that
key when a session starts. With five phases pinned, it drives the fan-out inside
`/phase-implement` and anything you type directly into the TUI. It does not
affect the pinned roles, which take their model from the `agent` block.

### Providers and secrets

Endpoints, keys and model IDs stay out of `opencode.json`. The file carries
placeholders that opencode substitutes when it loads the config.

```json
"options": {
  "baseURL": "http://{env:NODE_A_HOST}/v1",
  "apiKey":  "{env:NODE_A_API_KEY}"
}
```

Substitution also works mid-string, which is what lets the scheme and the `/v1`
path stay in `opencode.json` while only the address changes per deployment.
`NODE_A_HOST` carries the address and port together, because the port is what
distinguishes the two backends.

`{env:VAR}` reads the process environment. opencode does not read `.env` files
itself. Compose does, through `env_file: .env` in `docker-compose.yaml`, which
turns the file into real container environment that `{env:}` can see. A missing
variable resolves to an empty string instead of raising an error, so check
`docker compose config` first when a provider fails to connect.

`{file:./path}` is the other supported form, for keeping a key in its own file.

### Models

Substitution runs over the whole of `opencode.json`, including object keys, so
the entry in a provider's `models` map can itself be a placeholder.

```json
"models": {
  "{env:NODE_A_MODEL}": { "name": "{env:NODE_A_MODEL}", "tool_call": true }
}
```

Roles then bind to a node in the `agent` block and reuse the same variable, so
each model ID is written once.

```json
"agent": {
  "<role>": { "model": "node-a/{env:NODE_A_MODEL}" }
}
```

Which node a role talks to is an architecture decision and stays in
`opencode.json`. Which model that node serves is deployment config and lives in
`.env`. Retargeting a role is a one-line edit, and swapping models touches only
`.env`.

`tool_call: true` is deliberate. A model declared on a custom
`openai-compatible` provider carries no capability metadata from the registry,
and every role here edits files and runs commands, so the flag has to be stated.

Each node declares one model, so `NODE_*_MODEL` is the single source of truth
for what that machine serves. Adding a second model means adding another key to
the same `models` map.

Frontmatter is not substituted, in either agent or command files. Writing
`model: node-a/{env:X}` in `.opencode/agent/*.md` stores that string verbatim,
and `opencode debug agent architect` then reports `"modelID": "{env:X}"`. Only
`opencode.json` is substituted, which is why the bindings live there.

### Permissions

```json
"permission": {
  "edit": "ask",
  "bash": "ask",
  "external_directory": "deny"
}
```

`external_directory` gates paths outside the working directory. The Build agent
asks by default and this denies instead. Note what it does not do. Inside the
container the working directory is `/workspace`, so it blocks nothing within the
repo. That is intentional, because the repo is the agent's workspace and the
container boundary is what keeps the rest of the machine out of reach.

### Sandbox image

`Dockerfile` builds on `ghcr.io/anomalyco/opencode`, the published opencode
image. That base is Alpine plus the opencode binary and ripgrep, and nothing
else. It cannot run tests and has no git, so it adds three things.

Git, because the workflow has to produce commits or reviewable diffs and the
base image has none.

A language toolchain, passed in as the `LANG_PACKAGES` build argument rather
than written into the Dockerfile. The sandbox does not assume a language, so a
project in Go builds the same image with `LANG_PACKAGES=go` in `.env`. The
default is `nodejs npm python3`. Add `build-base` when native modules have to
compile.

An unprivileged `dev` user with uid 1000 and a real home directory. The compose
file runs as `1000:1000`, and without a passwd entry `HOME` falls back to `/`,
which that uid cannot write. Creating `/home/dev/.config/opencode` and
`/home/dev/.local/share/opencode` in the image also gives the named volumes
their ownership, because Docker seeds an empty volume from the image path it
covers.

The opencode version is pinned to `1.18.29`, the version every claim under
[What has been verified](#what-has-been-verified) was checked against. The
published image has since moved to `2.0.x`.

`.dockerignore` excludes everything except the Dockerfile. The repo arrives at
runtime as a bind mount, so sending it as build context would only slow the
build and copy `.env` into an image layer.

### Container

`docker-compose.yaml` runs opencode with the repo as its only mount.

```yaml
volumes:
  - .:/workspace
  - ./.opencode:/workspace/.opencode:ro
```

The host path is relative on purpose. Compose resolves relative bind mounts
against the directory holding the compose file rather than the shell's working
directory, so `docker compose -f /any/path/docker-compose.yaml up` still mounts
this repo. Compose reads `.env` by the same rule.

`.opencode` is mounted a second time read-only, on top of the writable repo
mount, so the agent running under those definitions cannot rewrite them.

`user: "1000:1000"` runs the agent unprivileged. Two named volumes,
`opencode-config` and `opencode-state`, keep opencode's own config and session
history out of the repo and persist them across `--rm` runs.

There is no `extra_hosts` block, because providers address the nodes by raw
tailnet IP. Mapping hostnames would describe each node twice, once as an address
for Compose and once as a hostname inside the base URL, with nothing keeping the
two in step. Addressing by IP also keeps the compose file free of interpolation,
so `.env` reaches opencode by one path only, `env_file:`.

`env_file:` does not inherit the host shell, so
`NODE_A_HOST=... docker compose run` will not override the file. Edit `.env`
instead.

### What has been verified

Checked against opencode `1.18.29` with `opencode debug config` and
`opencode debug agent`, rather than assumed from documentation.

| Claim | Result |
|---|---|
| `external_directory` is a real key, and `deny` overrides the built-in `ask` | Confirmed. Later rules win, and the user config merges last |
| `.opencode/agent/` and `.opencode/command/` are read | All 7 agents and 6 commands register |
| The plural `agents/` and `commands/` are also read | Confirmed. Neither spelling is ignored |
| `{env:VAR}` substitution | Resolves from the process environment only |
| `{env:VAR}` in a `models` key, and mid-string | Confirmed. Keys are substituted, and `http://{env:NODE_A_HOST}/v1` resolves |
| `{env:VAR}` in agent or command frontmatter | Not substituted. The literal string is stored |
| An unset variable | Resolves to an empty string rather than erroring |
| `agent.<role>.model` overrides the role file | Confirmed with `opencode debug agent <role>` |
| `agent:` in command frontmatter pins the role | Confirmed. All 5 appear as `agent=<role>` in the resolved config |
| `build` and `plan` carry no model | Confirmed. They resolve from the top-level `model` at session start |
| A `.env` file alone feeds `{env:}` | No. It needs `env_file:` in Compose |
| Relative bind mount resolves to this directory | Confirmed with `docker compose config` |
| `ghcr.io/anomalyco/opencode:1.18.29` is published and public | Confirmed against the GHCR API. The old `sst/opencode` path returns `DENIED` |
| The base image can run the workflow on its own | No. Its build history is Alpine, `libgcc libstdc++ ripgrep`, and the opencode binary. No git and no runtime |
| The `apk` packages the Dockerfile installs exist | Confirmed against the Alpine v3.24 package index, including `go` for a language swap |

Two carve-outs survive `external_directory: deny`. opencode re-adds its own
`tool-output` and temp directories after the user config, and no option disables
them. Inside the container both land in the `opencode-state` volume rather than
on the host filesystem.

`opencode agent create` writes to the plural `.opencode/agents/`. Both spellings
load, so it quietly produces a second directory beside the singular one.

### Not done yet

- The sandbox image has not been built or run, because no Docker daemon was
  available. The compose file resolves and the package names exist, but the
  build itself and the named-volume ownership are unverified.
- Agent and command bodies are `TODO` stubs.
- `.env.example` ships example addresses, `100.64.0.1` through `100.64.0.6`.
  Replace them with `tailscale ip -4` output from each machine.
- No model has been pulled by this repo. Each node needs its role's model
  present, as in the first tool chain.
- `AGENTS.md` has a `TODO` conventions section.

### Design notes

The two tool chains differ in where the sequencing lives. The first puts it in
`run-workflow.sh`, an explicit order with a human gate between phases, where the
model never chooses what runs next. The second puts it in opencode's own command
and agent files.

The gap is narrower than it first looks. Pinning `agent:` in command frontmatter
takes role selection away from the model, so five of six phases route as
deterministically as a script would. Only the fan-out inside `/phase-implement`
is still left to a model, and the user supplies the phase order by typing the
commands. The first chain's remaining advantage is that it enforces that order
instead of relying on convention.

That trade is the reason for building both. The script is more reproducible, and
the opencode version is less to maintain and gets a real sandbox boundary almost
for free.

### Security note

`.env` sits inside the `.:/workspace` mount, so the agent can read the keys with
`cat .env`. opencode's built-in defaults gate this, because `read` on `*.env`
and `*.env.*` resolves to `ask` and this config does not override `read`. That
makes it an approval prompt rather than a wall. To put the keys out of reach,
pass them through `environment:` in Compose from a file kept outside the
workspace.
