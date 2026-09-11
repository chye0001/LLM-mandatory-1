# Project instructions

<!-- Loaded into every opencode session in this project. Keep it short. -->

## Layout

- `src/` — implementation
- `tests/` — tests
- `docs/` — generated and hand-written documentation
- `.opencode/agent/` — one file per role
- `.opencode/command/` — phase drivers, invoked as `/phase-architecture` etc.

## Conventions

TODO: build/test commands, code style, commit conventions.

## Workflow

Work moves through phases, each driven by its `/phase-*` command:
architecture -> tickets -> implement -> test -> docs -> deploy.
