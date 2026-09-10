# Tool chain

Hermes agent, one profile per node, talking directly to each node's Ollama
endpoint over Tailscale. No gateway in between.

## Run

    cp .env.example .env               # fill in the node IPs (tailscale ip -4 on each node)
    ./bin/setup-hermes-profiles.sh      # binds each role to its Hermes profile
    hermes profile list                 # verify all six show the right model/provider

## Topology

Six nodes, one per assignment responsibility. Profile name == provider name ==
role, so `hermes --profile tester` talks straight to the tester node.

| Node | Profile | Responsibility | Model |
|---|---|---|---|
| node-a | `architect` | Architecture: decomposition, OpenAPI, topology, ADRs | llama3.1:8b |
| node-b | `techlead` | Tickets: scope, acceptance criteria, ordering | llama3.1:8b |
| node-c | `coder` | Implementation: multi-file repo changes | qwen2.5-coder:14b |
| node-d | `tester` | Tests + quality report, static checks, risks | qwen2.5-coder:14b |
| node-e | `docs` | README, API usage, runbook, design docs | llama3.1:8b |
| node-f | `deployer` | Dockerfile/compose, checklist, config docs | qwen2.5-coder:14b |

Each profile's `config.yaml` (under `~/.hermes/profiles/<role>/`) carries its
own `providers.<role>.base_url` pointing at that node, e.g.
`http://<node-c-ip>:11434/v1` for `coder`. `bin/setup-hermes-profiles.sh`
writes that block from the `.env` node IPs, so the six role/model/port
assignments stay identical for every teammate and only the IPs differ per
machine -- the same property `litellm-config.yaml` used to provide.

There is no load-balanced `worker` pool anymore (that was LiteLLM's
`least-busy` routing over node-c/d/f). The equivalent fan-out is now done
with the Hermes kanban board: create tasks assigned to `coder`, `tester` and
`deployer` and the dispatcher runs them concurrently, one per profile/node.
See [docs/orchestration-design.md](docs/orchestration-design.md) for how
task-level routing works there.

## Ollama on each node

Ollama defaults to `127.0.0.1:11434`, which is unreachable from other machines
*and* rejects requests whose `Host` header is not localhost (HTTP 403). 
On every node when testing production/staging setup, ensure the OLLAMA_HOST is your own Tailscale IP:

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

Each node must have pulled the model for its role (see the topology table):

    ollama pull llama3.1:8b         # node-a, node-b, node-e
    ollama pull qwen2.5-coder:14b   # node-c, node-d, node-f

With OLLAMA_MAX_LOADED_MODELS=1 each node serves exactly one model, so nothing
thrashes VRAM.

## Smoke test

    curl http://<node-c-ip>:11434/v1/chat/completions \
      -H "Content-Type: application/json" \
      -d '{"model":"qwen2.5-coder:14b","messages":[{"role":"user","content":"hi"}]}'

    hermes --profile coder chat -m "hi"

    NOTE:
    When doing the smoke test set the OLLAMA_HOST to 0.0.0.0. Otherwise it will fail, since Ollama automatically 
    rejects request that does not come from localhost/127.0.0.1 with 403.
