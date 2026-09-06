# Tool chain

LiteLLM gateway that fans inference out to several Ollama nodes over Tailscale.

## Run

    cp .env.example .env      # set the master key + the node IPs
    docker compose up -d
    curl http://127.0.0.1:4000/v1/models -H "Authorization: Bearer $LITELLM_MASTER_KEY"

`litellm-config.yaml` is mounted at `/app/config.yaml` and passed with
`--config`; without that flag LiteLLM starts with an empty model list.

## Topology

Six nodes, one per assignment responsibility. Profile name == model name ==
role, so `hermes --profile tester chat -m tester` reads as one thing.

| Node | Role | Responsibility | Model | In worker pool |
|---|---|---|---|---|
| node-a | `architect` | Architecture: decomposition, OpenAPI, topology, ADRs | llama3.1:8b | |
| node-b | `techlead` | Tickets: scope, acceptance criteria, ordering | llama3.1:8b | |
| node-c | `coder` | Implementation: multi-file repo changes | qwen2.5-coder:14b | yes |
| node-d | `tester` | Tests + quality report, static checks, risks | qwen2.5-coder:14b | yes |
| node-e | `docs` | README, API usage, runbook, design docs | llama3.1:8b | |
| node-f | `deployer` | Dockerfile/compose, checklist, config docs | qwen2.5-coder:14b | yes |

`worker` is a load-balanced pool over node-c, node-d and node-f -- the three
that already hold the coder model. Those two extra nodes are idle during the
implementation phase, so lending them to the fan-out gives N=3 concurrent
coding workers for free. This is what `delegation.model` targets in Hermes,
whose delegation config is global.

The `node-a`..`node-f` names are resolved by the `extra_hosts` block in
`docker-compose.yml`, reading each node's tailnet IP from `.env`. That keeps
`litellm-config.yaml` -- the submitted artifact -- byte-identical on every
teammate's machine.

## Ollama on each node

Ollama defaults to `127.0.0.1:11434`, which is unreachable from other machines
*and* rejects requests whose `Host` header is not localhost (HTTP 403). On every
node set:

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

    curl http://127.0.0.1:4000/v1/chat/completions \
      -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "Content-Type: application/json" \
      -d '{"model":"coder","messages":[{"role":"user","content":"hi"}]}'
