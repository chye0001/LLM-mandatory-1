#!/usr/bin/env bash
# Provisions the six role profiles directly in Hermes -- no LiteLLM gateway,
# no Docker. Each profile gets its own `providers` entry pointing straight at
# its node's Ollama OpenAI-compatible endpoint (http://<node>:11434/v1).
#
# This replaces litellm-config.yaml + docker-compose.yml. The node addresses
# still come from .env so the six role/model/port assignments below stay
# identical for every teammate; only the IPs differ per machine.
#
#   cp .env.example .env   # fill in NODE_*_IP from `tailscale ip -4` on each node
#   ./bin/setup-hermes-profiles.sh
#
# Safe to re-run: existing profiles are left in place and only their
# model/provider block is updated.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir/.."

if [ ! -f .env ]; then
  echo "Missing .env -- copy .env.example to .env and fill in the node IPs first." >&2
  exit 1
fi
set -a
source .env
set +a

# role:node-ip-var:model
ROLES=(
  "architect:NODE_A_IP:ggml-org/gemma-4-12B-it-GGUF:Q4_0"
  "techlead:NODE_B_IP:unsloth/Qwen3.5-9B-GGUF:Q4_K_XL"
  "coder:NODE_C_IP:unsloth/Qwen3.5-9B-GGUF:Q4_K_XL"
  "tester:NODE_D_IP:unsloth/Qwen3.5-9B-GGUF:Q4_K_XL"
  "docs:NODE_E_IP:unsloth/Qwen3.5-9B-GGUF:Q4_K_XL"
  "deployer:NODE_F_IP:unsloth/Qwen3.5-9B-GGUF:Q4_K_XL"
)

for entry in "${ROLES[@]}"; do
  role="${entry%%:*}"
  rest="${entry#*:}"
  ip_var="${rest%%:*}"
  model="${rest#*:}"
  ip="${!ip_var:-}"

  if [ -z "$ip" ]; then
    echo "Skipping $role: $ip_var is not set in .env" >&2
    continue
  fi

  if ! hermes profile show "$role" >/dev/null 2>&1; then
    echo "Creating profile: $role"
    hermes profile create "$role" --description "Role node for $role ($model)"
  fi

  profile_config="$HOME/.hermes/profiles/$role/config.yaml"
  echo "Binding $role -> http://$ip:11434/v1 ($model)"
  python3 "$script_dir/_bind_profile.py" "$profile_config" "$role" "$ip" "$model"
done

echo "Done. Verify with: hermes profile list"
