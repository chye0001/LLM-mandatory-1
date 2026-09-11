# Tool chain 2 — opencode in a container

The same six-responsibility pipeline as [`../first-toolchain`](../first-toolchain),
rebuilt on [opencode](https://opencode.ai) instead of Hermes. Two things change:

- **Sequencing lives in opencode**, not in a driver script. Each phase is a
  slash command under `.opencode/command/`, and each role is an agent under
  `.opencode/agent/`. There is no `run-workflow.sh` equivalent.
- **The agent runs in a container.** It sees the repo and nothing else, so a
  confused local model cannot reach the rest of the machine.

## Run

```sh
cp .env.example .env          # fill in the node endpoints and keys
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
opencode.json              providers (endpoints + keys) and global permissions
AGENTS.md                  project instructions, loaded into every session
docker-compose.yaml        the sandbox
.env                       endpoints and keys — not committed
.opencode/
  agent/                   one file per role
  command/                 phase drivers, invoked as /phase-architecture etc.
docs/  src/  tests/        the work product
```

## Roles

One file per role in `.opencode/agent/`. Role names match the first tool chain,
except that `coder` is split in two so implementation tickets can be worked in
parallel.

| Agent | Responsibility |
|---|---|
| `architect` | Architecture: decomposition, OpenAPI, topology, ADRs |
| `techlead` | Tickets: scope, acceptance criteria, ordering |
| `coder-a` | Implementation: assigned tickets |
| `coder-b` | Implementation: assigned tickets |
| `tester` | Tests and quality report, static checks, risks |
| `docwriter` | README, API usage, runbook, design docs |
| `deployer` | Dockerfile/compose, checklist, config docs |

All seven are declared `mode: subagent`, so a phase command delegates to them
rather than the user switching agent by hand.

**The bodies are stubs.** Every agent and command file currently contains
`TODO:` placeholders. The wiring is proven (see
[What has been verified](#what-has-been-verified)); the prompts are not written.

## Configuration

`opencode.json` holds both halves of the setup: which endpoint each role talks
to, and what the agent is allowed to do.

### Providers and secrets

Endpoints and keys are **not** written into `opencode.json`. The file carries
placeholders, which opencode substitutes at load time:

```json
"options": {
  "baseURL": "{env:NODE_A_BASE_URL}",
  "apiKey":  "{env:NODE_A_API_KEY}"
}
```

`{env:VAR}` reads the **process environment**. opencode does *not* read `.env`
files itself — Compose does, via `env_file: .env` in `docker-compose.yaml`,
which turns the file into real container environment where `{env:}` can see it.

> A variable that is missing resolves to an empty string rather than an error.
> If a provider fails to connect, check `docker compose config` first to confirm
> the value actually reached the container.

`{file:./path}` is the other supported form, if you would rather keep a key in
its own file than in the environment.

`models: {}` is empty for both providers — the model IDs per role still need
filling in.

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

`extra_hosts` maps the node names to tailnet addresses, so `node-a` resolves
inside the container without the container joining the tailnet:

```yaml
extra_hosts:
  - "node-a:100.x.y.z"
  - "node-b:100.x.y.w"
```

**These are placeholders.** Fill in real addresses from `tailscale ip -4` on
each node. Only two nodes are listed; the first tool chain uses six (`node-a`
through `node-f`), so this needs extending if the roles are spread the same way.

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
| `{file:./path}` substitution | Resolves from file contents |
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
- **`extra_hosts` IPs are placeholders**, and only cover two of six nodes.
- **`models: {}`** — no model IDs bound to roles yet.
- **`AGENTS.md`** has a `TODO` conventions section.

## Troubleshooting

**A provider gets an empty `baseURL` or `apiKey`.** The variable never reached
the container. `docker compose config` prints the resolved `environment:` block
— if the value is `""` there, the problem is `.env`, not opencode.

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
opencode's own command and agent files, which is less code but hands the phase
transition to the model inside a session.

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
