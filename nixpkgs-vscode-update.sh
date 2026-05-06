#!/usr/bin/env bash
# nixpkgs-vscode-update.sh — interactive automation for the VSCode nixpkgs update workflow
# Usage: ./nixpkgs-vscode-update.sh [OPTIONS]
# Run from inside the nixpkgs repo, or pass --nixpkgs-dir.
set -euo pipefail

# ── colour helpers ────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''
fi

info()    { printf "${CYAN}[info]${RESET}  %s\n" "$*"; }
ok()      { printf "${GREEN}[ok]${RESET}    %s\n" "$*"; }
warn()    { printf "${YELLOW}[warn]${RESET}  %s\n" "$*"; }
error()   { printf "${RED}[error]${RESET} %s\n" "$*" >&2; }
step()    { printf "\n${BOLD}━━━ %s${RESET}\n" "$*"; }
abort()   { error "$*"; exit 1; }

# ── option defaults ───────────────────────────────────────────────────────────
NIXPKGS_DIR=""
UPSTREAM_REMOTE_OVERRIDE=""
FORK_REMOTE_OVERRIDE=""
VERSION_ARG=""
DRY_RUN=false
BUILD_TESTED=false

# ── argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --nixpkgs-dir)  shift; NIXPKGS_DIR="$1" ;;
    --upstream)     shift; UPSTREAM_REMOTE_OVERRIDE="$1" ;;
    --fork)         shift; FORK_REMOTE_OVERRIDE="$1" ;;
    --version)      shift; VERSION_ARG="$1" ;;
    --dry-run)      DRY_RUN=true ;;
    -h|--help)
      cat <<'EOF'
nixpkgs-vscode-update.sh — interactive VSCode nixpkg update helper

Options:
  --nixpkgs-dir <path>   Path to nixpkgs checkout (default: current directory)
  --upstream <remote>    Name of the upstream NixOS/nixpkgs remote (auto-detected)
  --fork <remote>        Name of your fork remote (auto-detected)
  --version <X.Y.Z>      Specific VSCode version to target (default: latest)
  --dry-run              Walk through all steps without modifying anything
  -h, --help             Show this help

Run from inside the nixpkgs repo root, or pass --nixpkgs-dir.
Requires: git, nix, gh (authenticated), jq
EOF
      exit 0 ;;
    *) abort "Unknown option: $1  (try --help)" ;;
  esac
  shift
done

# ── confirm helper ────────────────────────────────────────────────────────────
# confirm "message" → returns 0 if user says yes, exits if no
confirm() {
  local prompt="$1"
  if [[ "$DRY_RUN" == true ]]; then
    printf "${YELLOW}[dry-run]${RESET} Would ask: %s → auto-yes\n" "$prompt"
    return 0
  fi
  printf "\n${BOLD}%s${RESET} [y/N] " "$prompt"
  local reply
  read -r reply
  case "$reply" in
    [Yy]|[Yy][Ee][Ss]) return 0 ;;
    *) abort "Aborted by user." ;;
  esac
}

# ── dry-run command wrapper ───────────────────────────────────────────────────
# run_cmd CMD [ARGS...] — executes normally, or just prints in dry-run mode
run_cmd() {
  if [[ "$DRY_RUN" == true ]]; then
    printf "${YELLOW}[dry-run]${RESET} Would run: %s\n" "$*"
  else
    "$@"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
step "Step 1 — Locate nixpkgs repo"
# ─────────────────────────────────────────────────────────────────────────────

VSCODE_UPDATE_SCRIPT="pkgs/applications/editors/vscode/update-vscode.sh"
VSCODE_NIX="pkgs/applications/editors/vscode/vscode.nix"

if [[ -n "$NIXPKGS_DIR" ]]; then
  NIXPKGS_DIR="$(realpath "$NIXPKGS_DIR")"
  [[ -d "$NIXPKGS_DIR" ]] || abort "Directory does not exist: $NIXPKGS_DIR"
  cd "$NIXPKGS_DIR"
fi

if [[ ! -f "$VSCODE_UPDATE_SCRIPT" ]]; then
  abort "Cannot find $VSCODE_UPDATE_SCRIPT in $(pwd)\nRun this script from the nixpkgs root, or pass --nixpkgs-dir <path>"
fi

info "nixpkgs directory: $(pwd)"
confirm "Use this nixpkgs directory?"

# ─────────────────────────────────────────────────────────────────────────────
step "Step 2 — Verify prerequisites"
# ─────────────────────────────────────────────────────────────────────────────

missing=()
for cmd in git nix gh jq; do
  if ! command -v "$cmd" &>/dev/null; then
    missing+=("$cmd")
  fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
  error "Missing required commands: ${missing[*]}"
  abort "Install the missing tools and try again."
fi
ok "All prerequisites found: git, nix, gh, jq"

# ─────────────────────────────────────────────────────────────────────────────
step "Step 3 — Verify gh authentication"
# ─────────────────────────────────────────────────────────────────────────────

if ! gh auth status &>/dev/null; then
  error "gh is not authenticated."
  info  "Run:  gh auth login"
  abort "Please authenticate with gh and try again."
fi
GITHUB_USER="$(gh api user --jq .login)"
ok "Authenticated as GitHub user: $GITHUB_USER"

# ─────────────────────────────────────────────────────────────────────────────
step "Step 4 — Check for clean working tree"
# ─────────────────────────────────────────────────────────────────────────────

DIRTY="$(git status --porcelain)"
if [[ -n "$DIRTY" ]]; then
  warn "Working tree has uncommitted changes:"
  git status --short
  confirm "Proceed anyway? (uncommitted changes may interfere)"
else
  ok "Working tree is clean."
fi

# ─────────────────────────────────────────────────────────────────────────────
step "Step 5 — Detect git remotes"
# ─────────────────────────────────────────────────────────────────────────────

detect_remote() {
  # detect_remote <pattern> → prints first remote whose URL matches pattern
  local pattern="$1"
  git remote -v | awk '/\(fetch\)/' | while read -r name url _; do
    if [[ "$url" == *"$pattern"* ]]; then
      echo "$name"
      return
    fi
  done
}

if [[ -n "$UPSTREAM_REMOTE_OVERRIDE" ]]; then
  UPSTREAM_REMOTE="$UPSTREAM_REMOTE_OVERRIDE"
else
  UPSTREAM_REMOTE="$(detect_remote "NixOS/nixpkgs")"
fi

if [[ -n "$FORK_REMOTE_OVERRIDE" ]]; then
  FORK_REMOTE="$FORK_REMOTE_OVERRIDE"
else
  FORK_REMOTE="$(detect_remote "${GITHUB_USER}/nixpkgs")"
  # fallback: try the remote called "origin" if URL matching didn't work
  if [[ -z "$FORK_REMOTE" ]]; then
    FORK_REMOTE="$(detect_remote "${GITHUB_USER}")"
  fi
fi

if [[ -z "$UPSTREAM_REMOTE" ]]; then
  warn "Could not auto-detect upstream remote. Current remotes:"
  git remote -v
  abort "Re-run with --upstream <remote-name>"
fi

if [[ -z "$FORK_REMOTE" ]]; then
  warn "Could not auto-detect your fork remote. Current remotes:"
  git remote -v
  abort "Re-run with --fork <remote-name>"
fi

info "Upstream remote : $UPSTREAM_REMOTE  ($(git remote get-url "$UPSTREAM_REMOTE"))"
info "Fork remote     : $FORK_REMOTE  ($(git remote get-url "$FORK_REMOTE"))"
confirm "These remotes look correct?"

# ─────────────────────────────────────────────────────────────────────────────
step "Step 6 — Fetch upstream and pull master"
# ─────────────────────────────────────────────────────────────────────────────

info "Fetching $UPSTREAM_REMOTE..."
run_cmd git fetch "$UPSTREAM_REMOTE"

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$CURRENT_BRANCH" != "master" ]]; then
  info "Currently on branch '$CURRENT_BRANCH' — switching to master"
  run_cmd git checkout master
fi

info "Pulling master from $UPSTREAM_REMOTE..."
run_cmd git pull "$UPSTREAM_REMOTE" master

if [[ "$DRY_RUN" == false ]]; then
  printf "\nRecent master commits:\n"
  git log --oneline -5
fi
confirm "Pull complete. Continue?"

# ─────────────────────────────────────────────────────────────────────────────
step "Step 7 — Push master to your fork"
# ─────────────────────────────────────────────────────────────────────────────

info "This will run: git push $FORK_REMOTE master"
confirm "Push updated master to your fork ($FORK_REMOTE)?"
run_cmd git push "$FORK_REMOTE" master
ok "Fork master is up to date."

# ─────────────────────────────────────────────────────────────────────────────
step "Step 8 — Check for existing open VSCode PRs in NixOS/nixpkgs"
# ─────────────────────────────────────────────────────────────────────────────

info "Querying open PRs with 'vscode' in the title..."
EXISTING_PRS="$(
  gh pr list --repo NixOS/nixpkgs \
    --search "vscode in:title" \
    --state open \
    --limit 50 \
    --json number,title,author,createdAt,url \
    | jq -r '
        [ .[] | select(.title | test("^vscode[: ][0-9]|^vscode$"; "i")) ]
        | if length == 0 then empty
          else .[] | "#\(.number) [\(.author.login)] \(.title)\n  \(.url)"
          end'
)"

if [[ -z "$EXISTING_PRS" ]]; then
  ok "No open PRs found for the main vscode package."
else
  printf "\n${YELLOW}Open vscode PRs in NixOS/nixpkgs:${RESET}\n\n"
  printf "%s\n" "$EXISTING_PRS"
fi

confirm "Aware of the above — continue with the update?"

# ─────────────────────────────────────────────────────────────────────────────
step "Step 9 — Read current vscode version"
# ─────────────────────────────────────────────────────────────────────────────

CURRENT_VERSION="$(grep -oP '(?<=version = ")[^"]+' "$VSCODE_NIX" | head -1)"
if [[ -z "$CURRENT_VERSION" ]]; then
  abort "Could not parse version from $VSCODE_NIX"
fi
ok "Current nixpkgs vscode version: $CURRENT_VERSION"

# ─────────────────────────────────────────────────────────────────────────────
step "Step 10 — Run the vscode update script"
# ─────────────────────────────────────────────────────────────────────────────

UPDATE_LOG="/tmp/nixpkgs-vscode-update-$$.log"

# Build command as an array so version arg is passed safely.
# Must run from the nixpkgs root — the script's nix commands use `-f .`
UPDATE_CMD=("./$VSCODE_UPDATE_SCRIPT")
if [[ -n "$VERSION_ARG" ]]; then
  info "Targeting specific version: $VERSION_ARG"
  UPDATE_CMD+=("$VERSION_ARG")
else
  info "No version specified — update script will fetch the latest release."
fi

warn "The update script fetches hashes for 5 platforms. This typically takes 3–10 minutes."
confirm "Run: ${UPDATE_CMD[*]}?"

if [[ "$DRY_RUN" == true ]]; then
  printf "${YELLOW}[dry-run]${RESET} Would run update script — skipping.\n"
  NEW_VERSION="${VERSION_ARG:-X.Y.Z}"
else
  # Execute from nixpkgs root — the script's #!/usr/bin/env nix-shell shebang handles its own env
  if ! "${UPDATE_CMD[@]}" 2>&1 | tee "$UPDATE_LOG"; then
    error "Update script exited with an error. Log: $UPDATE_LOG"
    abort "Check the log above for details."
  fi

  # Try to parse the new version from the script output
  NEW_VERSION="$(grep -oP '(?<=target\s{3}version: )[0-9]+\.[0-9]+(\.[0-9]+)?' "$UPDATE_LOG" | head -1 || true)"
  if [[ -z "$NEW_VERSION" ]]; then
    # Fall back to reading vscode.nix after the update
    NEW_VERSION="$(grep -oP '(?<=version = ")[^"]+' "$VSCODE_NIX" | head -1)"
  fi
fi

ok "New vscode version: $NEW_VERSION"

# ─────────────────────────────────────────────────────────────────────────────
step "Step 11 — Verify changes were made"
# ─────────────────────────────────────────────────────────────────────────────

if [[ "$DRY_RUN" == false ]]; then
  CHANGED_FILES="$(git diff --name-only)"
  if [[ -z "$CHANGED_FILES" ]]; then
    warn "No files were modified by the update script."
    warn "vscode may already be at the latest version ($CURRENT_VERSION)."
    abort "Nothing to commit — exiting."
  fi
  ok "Modified files:"
  git diff --stat
fi

# ─────────────────────────────────────────────────────────────────────────────
step "Step 12 — Review the diff"
# ─────────────────────────────────────────────────────────────────────────────

if [[ "$DRY_RUN" == false ]]; then
  printf "\n"
  git diff "$VSCODE_NIX"
fi

confirm "The diff looks correct — proceed to commit?"

# ─────────────────────────────────────────────────────────────────────────────
step "Step 13 — Test the build"
# ─────────────────────────────────────────────────────────────────────────────

printf "\n${BOLD}%s${RESET} [y/N] " "Run the build test now? (recommended — skipping will leave the PR checkbox unchecked)"
if [[ "$DRY_RUN" == true ]]; then
  printf "${YELLOW}[dry-run]${RESET} Would offer build test — skipping.\n"
else
  read -r _build_reply
  if [[ "$_build_reply" =~ ^[Yy] ]]; then
    # Detect running VSCode instances (process name is 'code' for the standard package)
    VSCODE_PIDS="$(pgrep -x code 2>/dev/null || true)"
    if [[ -n "$VSCODE_PIDS" ]]; then
      warn "Running VSCode instances detected (PIDs: $VSCODE_PIDS)"
      warn "VSCode must be closed before nix run can launch the freshly built version."
      printf "\n${BOLD}%s${RESET} [y/N] " "Kill all running VSCode instances?"
      read -r _kill_reply
      if [[ "$_kill_reply" =~ ^[Yy] ]]; then
        pkill -x code && ok "VSCode processes killed." || warn "pkill returned non-zero — processes may already be gone."
      else
        warn "Skipping kill — the build test may open alongside an existing instance."
      fi
    fi

    info "Launching: NIXPKGS_ALLOW_UNFREE=1 nix run -f . vscode"
    info "(Close VSCode when you are done testing — the script will resume.)"
    printf "\n"
    if NIXPKGS_ALLOW_UNFREE=1 nix run -f . vscode; then
      printf "\n${BOLD}%s${RESET} [y/N] " "Did VSCode launch and work correctly?"
      read -r _result_reply
      if [[ "$_result_reply" =~ ^[Yy] ]]; then
        BUILD_TESTED=true
        ok "Build test passed — will check the 'tested basic functionality' box in the PR."
      else
        warn "Build test marked as failed — checkbox will remain unchecked."
      fi
    else
      warn "nix run exited with an error — checkbox will remain unchecked."
    fi
  else
    warn "Build test skipped — 'tested basic functionality' checkbox will remain unchecked in the PR."
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
step "Step 14 — Create update branch"
# ─────────────────────────────────────────────────────────────────────────────

BRANCH="vscode-${NEW_VERSION}"
info "Branch to create: $BRANCH"
confirm "Create branch '$BRANCH'?"
run_cmd git checkout -b "$BRANCH"
ok "Now on branch: $BRANCH"

# ─────────────────────────────────────────────────────────────────────────────
step "Step 15 — Commit changes"
# ─────────────────────────────────────────────────────────────────────────────

COMMIT_MSG="vscode: ${CURRENT_VERSION} -> ${NEW_VERSION}"
info "Commit message: $COMMIT_MSG"

run_cmd git add "$VSCODE_NIX"
run_cmd git commit -m "$COMMIT_MSG"

if [[ "$DRY_RUN" == false ]]; then
  ok "Committed:"
  git log --oneline -1
fi

confirm "Commit looks correct — push branch and create PR?"

# ─────────────────────────────────────────────────────────────────────────────
step "Step 16 — Push branch to fork"
# ─────────────────────────────────────────────────────────────────────────────

run_cmd git push "$FORK_REMOTE" "$BRANCH"
ok "Branch pushed to $FORK_REMOTE."

# ─────────────────────────────────────────────────────────────────────────────
step "Step 17 — Create pull request"
# ─────────────────────────────────────────────────────────────────────────────

# Build the release notes URL: X.Y.Z → vX_Y
VERSION_MAJOR="$(echo "$NEW_VERSION" | cut -d. -f1)"
VERSION_MINOR="$(echo "$NEW_VERSION" | cut -d. -f2)"
RELEASE_URL="https://code.visualstudio.com/updates/v${VERSION_MAJOR}_${VERSION_MINOR}"

TESTED_MARK="$( [[ "$BUILD_TESTED" == true ]] && echo "x" || echo " " )"

PR_TITLE="vscode: ${CURRENT_VERSION} -> ${NEW_VERSION}"
PR_BODY="$(cat <<EOF
## Things done

Updated to ${NEW_VERSION} - [release notes ](${RELEASE_URL})

<!-- Please check what applies. Note that these are not hard requirements but merely serve as information for reviewers. -->

- Built on platform:
  - [x] x86_64-linux
  - [ ] aarch64-linux
  - [ ] x86_64-darwin
  - [ ] aarch64-darwin
- Tested, as applicable:
  - [ ] [NixOS tests] in [nixos/tests].
  - [ ] [Package tests] at \`passthru.tests\`.
  - [ ] Tests in [lib/tests] or [pkgs/test] for functions and "core" functionality.
- [ ] Ran \`nixpkgs-review\` on this PR. See [nixpkgs-review usage].
- [${TESTED_MARK}] Tested basic functionality of all binary files, usually in \`./result/bin/\`.
- Nixpkgs Release Notes
  - [ ] Package update: when the change is major or breaking.
- NixOS Release Notes
  - [ ] Module addition: when adding a new NixOS module.
  - [ ] Module update: when the change is significant.
- [ ] Fits [CONTRIBUTING.md], [pkgs/README.md], [maintainers/README.md] and other READMEs.

[NixOS tests]: https://nixos.org/manual/nixos/unstable/index.html#sec-nixos-tests
[Package tests]: https://github.com/NixOS/nixpkgs/blob/master/pkgs/README.md#package-tests
[nixpkgs-review usage]: https://github.com/Mic92/nixpkgs-review#usage

[CONTRIBUTING.md]: https://github.com/NixOS/nixpkgs/blob/master/CONTRIBUTING.md
[lib/tests]: https://github.com/NixOS/nixpkgs/blob/master/lib/tests
[maintainers/README.md]: https://github.com/NixOS/nixpkgs/blob/master/maintainers/README.md
[nixos/tests]: https://github.com/NixOS/nixpkgs/blob/master/nixos/tests
[pkgs/README.md]: https://github.com/NixOS/nixpkgs/blob/master/pkgs/README.md
[pkgs/test]: https://github.com/NixOS/nixpkgs/blob/master/pkgs/test
EOF
)"

printf "\n${BOLD}PR title:${RESET} %s\n" "$PR_TITLE"
printf "${BOLD}PR body:${RESET}\n%s\n" "$PR_BODY"

confirm "Create this PR against NixOS/nixpkgs master?"

if [[ "$DRY_RUN" == true ]]; then
  printf "${YELLOW}[dry-run]${RESET} Would run: gh pr create ...\n"
  PR_URL="https://github.com/NixOS/nixpkgs/pull/XXXXX (dry-run)"
else
  PR_URL="$(gh pr create \
    --repo NixOS/nixpkgs \
    --base master \
    --head "${GITHUB_USER}:${BRANCH}" \
    --title "$PR_TITLE" \
    --body "$PR_BODY")"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "Done"
# ─────────────────────────────────────────────────────────────────────────────

printf "\n${GREEN}${BOLD}VSCode update complete!${RESET}\n\n"
printf "  Branch  : %s\n" "$BRANCH"
printf "  Commit  : %s\n" "$(git log --oneline -1 2>/dev/null || echo '(dry-run)')"
printf "  PR      : %s\n" "$PR_URL"
printf "\nTo test the build locally:\n"
printf "  NIXPKGS_ALLOW_UNFREE=1 nix run -f . vscode\n"

if [[ -f "$UPDATE_LOG" ]]; then
  rm -f "$UPDATE_LOG"
fi
