#!/usr/bin/env python3
"""Merge a node binding into a Hermes profile's config.yaml in place.

Used by setup-hermes-profiles.sh -- not meant to be run standalone.
"""
import sys
import yaml

path, role, ip, model = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
base_url = f"http://{ip}:11434/v1"

with open(path) as f:
    config = yaml.safe_load(f) or {}

config["model"] = {"default": model, "provider": role, "base_url": base_url}
providers = config.setdefault("providers", {})
providers[role] = {
    "name": role,
    "base_url": base_url,
    "model": model,
    "discover_models": True,
}

with open(path, "w") as f:
    yaml.safe_dump(config, f, sort_keys=False)
