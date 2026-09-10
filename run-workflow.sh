#!/usr/bin/env bash
#
# run-workflow.sh -- drives the six-role Hermes pipeline end to end.
#
# Design notes: docs/workflow-script-design.md (the "what")
#               docs/orchestration-design.md   (the "why")
#
# Each phase is a separate `hermes --profile <role>` process. The profile owns
# the endpoint (api base URL + model) and the toolset, so this script never
# selects a model -- it selects a role, and the profile decides which node that
# role runs on. There is no router in the path.
#
# Bash 3.2 compatible on purpose: no associative arrays, no mapfile, no ${x^^}.
# Runs unmodified under Git Bash on Windows and /bin/bash on macOS.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# The fixed brief. Committed, diffable, identical on every run -- this is what
# makes the rerun comparison meaningful. Edit it here, not at the prompt.
FIXED_BRIEF="Build a small REST API for tracking a personal reading list.

A user can add a book (title, author, ISBN, and a status of 'to-read',
'reading' or 'done'), list books with an optional filter on status, update a
book's status, and delete a book. Data persists to a single SQLite file.
Python with FastAPI and Pydantic models. No authentication, no external
services, no front end.

The service must start with uvicorn, expose interactive docs at /docs, and ship
with pytest tests covering each endpoint including the not-found cases."

# Everything generated lands under one of these, so the pipeline never collides
# with the toolchain's own README.md and docker-compose.yml at the repo root.
APP_DIR="app"            # the implementation the pipeline builds
DOC_DIR="docs"           # brief, tickets, ADRs, reports
ART_DIR="artifacts"      # architecture notes, rendered prompts, phase logs

PROMPT_DIR="$ART_DIR/prompts"
LOG_DIR="$ART_DIR/logs"

# Hermes runs without a per-command approval prompt inside a phase; the gate
# below is the control point instead. Set HERMES_YOLO=0 to keep the prompts,
# but be aware that an approval prompt in a -q run has no TUI to answer it and
# will hang the script.
HERMES_YOLO="${HERMES_YOLO:-1}"

# Cap tool-calling iterations per phase so a confused local model cannot spin.
MAX_TURNS="${MAX_TURNS:-90}"

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

say()  { printf '%s\n' "$*"; }
rule() { printf '%s\n' "------------------------------------------------------------"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# Where interactive reads come from. Held on a dedicated descriptor so that -i
# mode -- which reads the brief from stdin until EOF -- cannot leave the gate
# reading an exhausted stdin and spinning forever.
#
# A controlling terminal is not guaranteed: piped input, CI and a backgrounded
# run all lack one. Testing [ -r /dev/tty ] is not enough, because the file can
# be readable while the open still fails with ENXIO, so open it for real here.
TTY_IN=0
if ( : < /dev/tty ) 2>/dev/null; then
  exec 3< /dev/tty
  TTY_IN=3
fi

# ask <prompt-string> -> echoes the answer on stdout; returns 1 at end of input.
# The prompt goes to stderr so it is never captured by the caller's $( ).
ask() {
  local reply=""
  printf '%s' "$1" >&2
  if IFS= read -r reply <&$TTY_IN; then
    printf '%s' "$reply"
    return 0
  fi
  printf '\n' >&2
  return 1
}

# Emit a file's contents, or a clear marker when it is absent, so a missing
# upstream artifact shows up inside the prompt instead of failing the run.
read_artifact() {
  if [ -f "$1" ]; then
    cat "$1"
  else
    printf '(%s does not exist)' "$1"
  fi
}

# Same, for an artifact that legitimately may not exist. An OpenAPI document is
# the right contract for an HTTP service and meaningless for a CLI tool, so its
# absence must not read to the next phase as a failed upstream phase.
read_optional() {
  if [ -f "$1" ]; then
    cat "$1"
  else
    printf '(no %s -- the architect judged it not applicable to this brief)' "$1"
  fi
}

# Emit a file listing for a directory, for docs/adr and the app source tree.
read_tree() {
  if [ -d "$1" ]; then
    find "$1" -type f | sort | sed 's/^/  /'
  else
    printf '  (%s does not exist)' "$1"
  fi
}

usage() {
  cat <<'USAGE_EOF'
Usage:
  ./run-workflow.sh                        Run the fixed brief (reproducible)
  ./run-workflow.sh -m "build feature x"   Brief inline
  ./run-workflow.sh -f docs/brief.md       Brief from a file
  ./run-workflow.sh -i                     Brief typed in, ended with Ctrl-D
  ./run-workflow.sh -h                     This message

Whichever mode runs, the effective brief is written to docs/brief.md and
committed before phase 1, so an interactive run stays reproducible by a third
party: the output of an interactive run is the input to a fixed one.

Environment:
  HERMES_YOLO=0    Keep per-command approval prompts (will hang a -q run)
  MAX_TURNS=N      Cap tool-calling iterations per phase (default 90)
USAGE_EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

BRIEF=""
BRIEF_SOURCE="fixed"

while [ $# -gt 0 ]; do
  case "$1" in
    -m)
      [ $# -ge 2 ] || die "-m needs a brief. Quote it: -m \"build feature x\""
      BRIEF="$2"; BRIEF_SOURCE="inline"; shift 2 ;;
    -f)
      [ $# -ge 2 ] || die "-f needs a path"
      [ -f "$2" ] || die "no such file: $2"
      BRIEF="$(cat "$2")"; BRIEF_SOURCE="file:$2"; shift 2 ;;
    -i)
      say "Type the brief. Ctrl-D on a blank line when you are done."
      rule
      BRIEF="$(cat)"
      BRIEF_SOURCE="interactive"; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "unknown argument: $1 (try -h)" ;;
  esac
done

if [ -z "$BRIEF" ]; then
  if [ "$BRIEF_SOURCE" != "fixed" ]; then
    die "the brief from $BRIEF_SOURCE is empty"
  fi
  BRIEF="$FIXED_BRIEF"
fi

# ---------------------------------------------------------------------------
# Preflight and run isolation
# ---------------------------------------------------------------------------

command -v hermes >/dev/null 2>&1 || die "hermes is not on PATH"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repository"

cd "$(git rev-parse --show-toplevel)"

if [ -n "$(git status --porcelain)" ]; then
  say "Working tree is not clean:"
  git --no-pager status --short
  rule
  die "commit or stash first -- a run must start from a clean base so that
       'git diff run-A run-B' is the whole rerun comparison."
fi

RUN_ID="run-$(date +%Y%m%d-%H%M%S)"
BASE_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
git checkout -q -b "$RUN_ID"

mkdir -p "$DOC_DIR" "$ART_DIR" "$PROMPT_DIR" "$LOG_DIR"

say ""
rule
say "  run:    $RUN_ID"
say "  base:   $BASE_BRANCH"
say "  brief:  $BRIEF_SOURCE"
rule
say ""

# ---------------------------------------------------------------------------
# Phase 0 -- capture the brief
# ---------------------------------------------------------------------------

{
  printf '# Brief\n\n'
  printf 'Source: %s\n' "$BRIEF_SOURCE"
  printf 'Run: %s\n\n' "$RUN_ID"
  printf '%s\n' "$BRIEF"
} > "$DOC_DIR/brief.md"

git add "$DOC_DIR/brief.md"
git commit -q -m "phase 0: capture brief ($BRIEF_SOURCE)"
say "phase 0: brief captured -> $DOC_DIR/brief.md"
say ""

# ---------------------------------------------------------------------------
# Prompts
#
# Rendered to a file rather than passed on argv. Windows caps a command line at
# roughly 32 KB and a prompt carrying architecture.md plus openapi.yaml goes
# past that. Writing them out also leaves a committed record of the exact text
# each phase received, which is the reproducibility claim in the design doc.
# ---------------------------------------------------------------------------

render_prompt() {
  # render_prompt <phase-key> <output-path>
  local key="$1" out="$2"

  case "$key" in

  architect)
    cat > "$out" <<PROMPT_EOF
You are the ARCHITECT. You produce design only. Write no application code.

BRIEF
$(read_artifact "$DOC_DIR/brief.md")

TASK
Begin $ART_DIR/architecture.md with a section "Understanding of the brief"
restating, in your own words, what is being asked for and what is explicitly
out of scope. This is read at the first approval gate before any other phase
runs, so be precise rather than generous.

Then produce these files:

1. $ART_DIR/architecture.md -- the understanding section above, then the
   component decomposition, the responsibility of each component, the data
   model if there is one, the language and runtime, how the thing is started,
   and how it is deployed or distributed.
2. $DOC_DIR/interface.md -- the interface contract. Every operation the brief
   implies, its inputs, its outputs, and its failure behaviour. Describe it in
   whatever form actually fits what is being built: HTTP endpoints for a web
   service, commands and flags and exit codes for a command line tool, public
   functions and their signatures for a library.
3. $DOC_DIR/openapi.yaml -- ONLY if the brief describes an HTTP service. A
   valid OpenAPI 3.0 document covering every endpoint, with request and
   response schemas and the error responses. If the brief does not describe an
   HTTP service, do not create this file at all; say so in one line in
   $ART_DIR/architecture.md instead.
4. $DOC_DIR/adr/0001-<slug>.md and further numbered files -- one Architecture
   Decision Record per significant choice, each with Context, Decision and
   Consequences.

CONSTRAINTS
- Do not create files under $APP_DIR. Implementation is a later phase.
- Do not write tests, Dockerfiles or README files.
- Let the brief decide the shape. Do not turn a command line tool into a web
  service, or a single script into a multi-service system, because the design
  is easier to write that way.
- Keep the design proportional to the brief. Do not add services, queues,
  caches or authentication that the brief did not ask for.
PROMPT_EOF
    ;;

  techlead)
    cat > "$out" <<PROMPT_EOF
You are the TECH LEAD. You turn a design into tickets. Write no application
code.

BRIEF
$(read_artifact "$DOC_DIR/brief.md")

ARCHITECTURE
$(read_artifact "$ART_DIR/architecture.md")

INTERFACE CONTRACT
$(read_artifact "$DOC_DIR/interface.md")

OPENAPI DOCUMENT
$(read_optional "$DOC_DIR/openapi.yaml")

TASK
Write $DOC_DIR/tickets.md: an ordered list of implementation tickets covering
the whole design and nothing beyond it.

Each ticket has:
- an id of the form T-01, T-02, and so on
- a one-line title
- scope: the files it is allowed to touch
- acceptance criteria: concrete checkable statements, not aspirations
- depends on: the ticket ids that must land first, or the word none

CONSTRAINTS
- Order the tickets so that dependencies always come first.
- Every operation in the interface contract must be covered by some ticket.
- A ticket must be small enough to finish in one sitting.
- Do not create or modify any file other than $DOC_DIR/tickets.md.
PROMPT_EOF
    ;;

  coder)
    cat > "$out" <<PROMPT_EOF
You are the IMPLEMENTER. You write the application.

BRIEF
$(read_artifact "$DOC_DIR/brief.md")

ARCHITECTURE
$(read_artifact "$ART_DIR/architecture.md")

TICKETS
$(read_artifact "$DOC_DIR/tickets.md")

INTERFACE CONTRACT
$(read_artifact "$DOC_DIR/interface.md")

OPENAPI DOCUMENT
$(read_optional "$DOC_DIR/openapi.yaml")

TASK
Implement every ticket, in dependency order, under $APP_DIR/.

Deliver:
- the application source, in the language and runtime the architecture chose
- a dependency manifest in whatever form that stack uses, with versions pinned
  (requirements.txt, package.json, go.mod, and so on) -- omit it only if the
  thing genuinely has no dependencies
- the entry point the architecture specifies, working from inside $APP_DIR

CONSTRAINTS
- Write only under $APP_DIR/. Do not touch the repository README.md,
  docker-compose.yml, litellm-config.yaml, $DOC_DIR/ or $ART_DIR/.
- Implement what the tickets say. Where a ticket is ambiguous, follow the
  interface contract; where both are silent, choose the smaller option and note
  the choice in a code comment.
- The interface must match the contract exactly: the same names, the same
  inputs, the same outputs, the same failure behaviour.
- Build what the architecture describes. Do not add a web server, a database or
  a framework that it does not call for.
- Do not write the test suite. That is the next phase.
PROMPT_EOF
    ;;

  tester)
    cat > "$out" <<PROMPT_EOF
You are the TESTER. You write and run tests, then report honestly.

BRIEF
$(read_artifact "$DOC_DIR/brief.md")

ARCHITECTURE
$(read_artifact "$ART_DIR/architecture.md")

TICKETS AND THEIR ACCEPTANCE CRITERIA
$(read_artifact "$DOC_DIR/tickets.md")

INTERFACE CONTRACT
$(read_artifact "$DOC_DIR/interface.md")

IMPLEMENTATION FILES
$(read_tree "$APP_DIR")

TASK
1. Write tests under $APP_DIR/tests/ covering every operation in the interface
   contract, including the failure cases: bad input, missing input, and asking
   for something that does not exist. Use the test framework idiomatic for the
   stack that was actually built -- pytest for Python, and so on.
2. Actually run them, from inside $APP_DIR, and read the output.
3. Write $DOC_DIR/quality-report.md containing the exact command you ran, the
   real pass and fail counts, every failure with its cause, each ticket's
   acceptance criteria marked met or not met, and the risks you see.

CONSTRAINTS
- Do not claim a test passed without having run it. This script re-runs the
  suite itself after you finish and prints the real exit code next to your
  report, so an inaccurate report is visible immediately.
- You may fix the implementation under $APP_DIR/ when a test exposes a genuine
  bug. Say so in the report when you do.
- Do not weaken or delete a test to make the suite green.
PROMPT_EOF
    ;;

  docs)
    cat > "$out" <<PROMPT_EOF
You are the DOCUMENTATION writer. Write no application code.

BRIEF
$(read_artifact "$DOC_DIR/brief.md")

ARCHITECTURE
$(read_artifact "$ART_DIR/architecture.md")

INTERFACE CONTRACT
$(read_artifact "$DOC_DIR/interface.md")

QUALITY REPORT
$(read_artifact "$DOC_DIR/quality-report.md")

IMPLEMENTATION FILES
$(read_tree "$APP_DIR")

TASK
Produce exactly these files:

1. $APP_DIR/README.md -- what this is, how to install it, how to run it, and
   how to run its tests.
2. $DOC_DIR/usage.md -- a worked example of every operation in the interface
   contract, in the form a user would actually invoke it: curl for an HTTP
   service, a shell command line for a CLI tool, a code snippet for a library.
   Show the real input and the output it produces.
3. $DOC_DIR/runbook.md -- how to operate it: how to start and stop it if it is
   long-running, where its data lives if it has any, what the common failures
   look like and what to do about each.

CONSTRAINTS
- Do not modify the repository root README.md. That file documents the
  toolchain, not this application, and overwriting it destroys the setup guide.
- Every command you write must be one that works against the implementation as
  it actually exists. Read the source before documenting a flag or a path.
- Do not document operations or options that are not implemented.
PROMPT_EOF
    ;;

  deployer)
    cat > "$out" <<PROMPT_EOF
You are the DEPLOYMENT engineer.

BRIEF
$(read_artifact "$DOC_DIR/brief.md")

ARCHITECTURE
$(read_artifact "$ART_DIR/architecture.md")

IMPLEMENTATION FILES
$(read_tree "$APP_DIR")

RUNBOOK
$(read_artifact "$DOC_DIR/runbook.md")

TASK
Package what was built so that someone else can run it.

1. $APP_DIR/Dockerfile -- builds and runs it. Pin the base image tag. Do not
   run as root. Write this for anything that can sensibly be containerised,
   including a command line tool.
2. $APP_DIR/docker-compose.yml -- ONLY if this is a long-running service. Put
   any persistent data on a named volume so it survives a restart. If the thing
   is a one-shot command rather than a service, skip this file and say so in
   one line in the checklist.
3. $APP_DIR/.dockerignore
4. $DOC_DIR/deployment-checklist.md -- the ordered steps to deploy or
   distribute it, what to verify after each, and how to roll back.
5. $DOC_DIR/configuration.md -- every environment variable and setting, its
   default, and what changes when you change it. If there is no configuration
   at all, say exactly that in one line rather than inventing settings.

CONSTRAINTS
- Do not modify the repository root docker-compose.yml. That file runs the
  toolchain's own gateway and has nothing to do with this application.
- Build the image yourself and fix what breaks. This script runs "docker build"
  after you finish and prints the real result, so an image that does not build
  is visible immediately.
- If docker is unavailable in your environment, say so plainly in the checklist
  rather than claiming a successful build.
PROMPT_EOF
    ;;

  *)
    die "no prompt defined for phase '$key'" ;;
  esac
}

# ---------------------------------------------------------------------------
# Running a phase
# ---------------------------------------------------------------------------

run_phase() {
  # run_phase <n> <phase-key> <attempt> <feedback-or-empty>
  local n="$1" key="$2" attempt="$3" feedback="$4"
  local prompt_file="$PROMPT_DIR/$n-$key.md"
  local log_file="$LOG_DIR/$n-$key-attempt$attempt.log"

  render_prompt "$key" "$prompt_file"

  if [ -n "$feedback" ]; then
    {
      printf '\n\nCORRECTION FROM THE PREVIOUS ATTEMPT\n'
      printf 'Your last attempt at this phase was rejected for this reason:\n\n'
      printf '%s\n' "$feedback"
      printf '\nAddress it. Keep whatever was already correct.\n'
    } >> "$prompt_file"
  fi

  # Deliberately unquoted below so the flags split into separate arguments.
  local flags="--profile $key"
  if [ "$HERMES_YOLO" = "1" ]; then
    flags="$flags --yolo"
  fi

  rule
  say "phase $n: $key   (attempt $attempt)"
  say "  profile: $key -- endpoint and model come from the profile"
  say "  prompt:  $prompt_file"
  say "  log:     $log_file"
  rule

  # The prompt is on disk; the agent gets a pointer to it rather than the text,
  # which keeps the command line under the Windows 32 KB limit.
  set +e
  hermes $flags chat \
    --max-turns "$MAX_TURNS" \
    -q "Read the file $prompt_file and carry out every instruction in it exactly. That file is your full task; do not ask for confirmation." \
    2>&1 | tee "$log_file"
  local rc=${PIPESTATUS[0]}
  set -e

  if [ "$rc" -ne 0 ]; then
    say ""
    say "  hermes exited $rc -- see $log_file"
  fi
  say ""
}

# ---------------------------------------------------------------------------
# Verification -- checked by the script, not taken from the model's report
# ---------------------------------------------------------------------------

verify_phase() {
  # verify_phase <phase-key>
  local key="$1"
  local prc=0 drc=0

  case "$key" in
  tester)
    rule
    say "verify: running the test suite"
    rule
    if [ ! -d "$APP_DIR" ]; then
      say "  $APP_DIR does not exist -- nothing to test."
      say ""
      return 0
    fi

    # The brief decides the stack, so the script has to find the suite rather
    # than assume one. Detection order matches how obvious the signal is.
    # The runner has to be checked as well as the suite. Without that, a missing
    # pytest looks identical to a failing test suite, and the phase gets blamed
    # for a gap in this machine's environment.
    local test_cmd="" missing=""
    if [ -n "$(find "$APP_DIR" -name 'test_*.py' -o -name '*_test.py' 2>/dev/null | head -1)" ]; then
      if ! command -v python >/dev/null 2>&1; then
        missing="python is not on PATH"
      elif ! python -c "import pytest" >/dev/null 2>&1; then
        missing="python is present but pytest is not installed (pip install pytest)"
      else
        test_cmd="python -m pytest -q"
      fi
    elif [ -f "$APP_DIR/package.json" ] && grep -q '"test"' "$APP_DIR/package.json"; then
      if command -v npm >/dev/null 2>&1; then
        test_cmd="npm test"
      else
        missing="npm is not on PATH"
      fi
    elif [ -f "$APP_DIR/go.mod" ]; then
      if command -v go >/dev/null 2>&1; then
        test_cmd="go test ./..."
      else
        missing="go is not on PATH"
      fi
    fi

    if [ -z "$test_cmd" ]; then
      if [ -n "$missing" ]; then
        say "  Found a test suite but cannot run it: $missing."
      else
        say "  No test suite found that this script knows how to run."
      fi
      say "  This phase is UNVERIFIED -- read quality-report.md critically,"
      say "  and do not treat its claims as checked."
      say ""
      return 0
    fi

    say "  running: $test_cmd  (in $APP_DIR)"
    say ""
    set +e
    ( cd "$APP_DIR" && $test_cmd ) 2>&1 | tee "$LOG_DIR/verify-tests.log"
    prc=${PIPESTATUS[0]}
    set -e
    say ""
    if [ "$prc" -eq 0 ]; then
      say "  exit 0 -- the suite passes."
    else
      say "  exit $prc -- the suite does NOT pass."
      say "  Compare that against what quality-report.md claims before accepting."
    fi
    say ""
    ;;

  deployer)
    rule
    say "verify: building the image"
    rule
    if ! command -v docker >/dev/null 2>&1; then
      say "  docker is not on PATH -- cannot verify. Treat the checklist as unverified."
      say ""
      return 0
    fi
    if [ ! -f "$APP_DIR/Dockerfile" ]; then
      say "  $APP_DIR/Dockerfile does not exist -- nothing to build."
      say ""
      return 0
    fi
    set +e
    docker build -t "$RUN_ID-app" "$APP_DIR" 2>&1 | tee "$LOG_DIR/verify-docker.log"
    drc=${PIPESTATUS[0]}
    set -e
    say ""
    if [ "$drc" -eq 0 ]; then
      say "  docker build exit 0 -- the image builds."
    else
      say "  docker build exit $drc -- the image does NOT build."
    fi
    say ""
    ;;
  esac
}

# ---------------------------------------------------------------------------
# The approval gate
#
# Returns 0 accept, 1 retry (and sets GATE_FEEDBACK), 2 abort-keep,
# 3 abort-discard.
# ---------------------------------------------------------------------------

GATE_FEEDBACK=""

gate() {
  # gate <n> <phase-key>
  local n="$1" key="$2"
  local reply confirm line acc

  # Register new files as empty so they show up in the diff. Without this the
  # architecture phase -- whose output is entirely new files -- displays a near
  # empty diff and is then committed unreviewed by the git add -A below.
  git add -A -N

  rule
  say "review: phase $n ($key)"
  rule
  git --no-pager diff --stat
  say ""
  say "  working tree:"
  git --no-pager status --short | sed 's/^/  /'
  say ""

  while :; do
    say "  [a] accept and commit    [v] view the full diff"
    say "  [r] retry with feedback  [k] abort, keep changes"
    say "  [d] abort and discard"
    if ! reply="$(ask '  > ')"; then
      say ""
      say "  End of input -- there is nobody here to approve this phase."
      say "  Stopping with the changes kept."
      say ""
      return 2
    fi

    case "$reply" in
      a|A)
        git add -A
        if git diff --cached --quiet; then
          say ""
          say "  Nothing to commit -- this phase produced no changes at all."
          say "  That is normally a failed phase. Retry it or abort."
          say ""
          continue
        fi
        git commit -q -m "phase $n: $key"
        say "  committed: phase $n: $key"
        say ""
        return 0 ;;

      v|V)
        git --no-pager diff
        say "" ;;

      r|R)
        say "  What went wrong? One or more lines, blank line to finish."
        acc=""
        while :; do
          line="$(ask '  | ')" || break
          [ -z "$line" ] && break
          acc="$acc$line
"
        done
        if [ -z "$acc" ]; then
          say "  No feedback given -- not retrying blind."
          say ""
          continue
        fi
        GATE_FEEDBACK="$acc"
        # Roll the rejected output back so the retry starts where the first
        # attempt did rather than layering onto work already judged wrong. The
        # phase logs are excluded so the record of the failed attempt survives
        # into the eventual commit.
        git reset -q
        git checkout -- .
        git clean -qfd -e "$LOG_DIR"
        say "  reverted. re-running phase $n with your feedback."
        say ""
        return 1 ;;

      k|K)
        say ""
        say "  Stopping. The working tree is left dirty on branch $RUN_ID."
        say "  Inspect it with:  git status"
        say "  Leave it with:    git checkout $BASE_BRANCH"
        say ""
        return 2 ;;

      d|D)
        say "  This permanently deletes every uncommitted file, new ones"
        say "  included. Type the word discard to confirm, anything else to"
        say "  cancel."
        confirm="$(ask '  > ')" || confirm=""
        if [ "$confirm" = "discard" ]; then
          return 3
        fi
        say "  cancelled."
        say "" ;;

      *)
        say "  Not one of a, v, r, k, d."
        say "" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# The pipeline
# ---------------------------------------------------------------------------

PHASES="1:architect 2:techlead 3:coder 4:tester 5:docs 6:deployer"

for spec in $PHASES; do
  n="${spec%%:*}"
  key="${spec#*:}"

  feedback=""
  attempt=1

  while :; do
    GATE_FEEDBACK=""
    run_phase "$n" "$key" "$attempt" "$feedback"
    verify_phase "$key"

    rc=0
    gate "$n" "$key" || rc=$?

    case "$rc" in
      0) break ;;
      1)
        feedback="$GATE_FEEDBACK"
        attempt=$((attempt + 1))
        continue ;;
      2) exit 0 ;;
      3)
        git reset -q
        git checkout -- .
        git clean -qfd
        say ""
        say "  Discarded. Branch $RUN_ID keeps the phases committed before this one."
        say "  git checkout $BASE_BRANCH to leave it."
        say ""
        exit 0 ;;
    esac
  done
done

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

say ""
rule
say "  all six phases accepted"
rule
say ""
say "  branch:  $RUN_ID"
say "  commits:"
git --no-pager log --oneline "$BASE_BRANCH..$RUN_ID" | sed 's/^/    /'
say ""
say "  compare two runs with:"
say "    git diff <other-run-branch> $RUN_ID"
say ""
