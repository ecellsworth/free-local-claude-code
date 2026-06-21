#!/usr/bin/env bash
#
# setup-claude-ollama.command
# ===========================================================================
# Implements the setup process from the dev.to article
#   "Run Claude for FREE Locally (Using Ollama + Claude Code)"
# as a single, robust, ZERO-COST, fully OFFLINE installer for macOS or Linux.
#
# The article's concept (validated and corrected here):
#   1. Install Ollama                        (local LLM engine)
#   2. Install Claude Code                    (the coding CLI)
#   3. Pull a local coding model              (qwen2.5-coder:7b)
#   4. Configure the environment so Claude Code uses the LOCAL model
#   5. Launch:  ollama launch claude  (or just `claude`)
#
# Validation notes (see VALIDATION.md for the full write-up):
#   * Ollama now serves an Anthropic-compatible API on localhost, so the
#     article's idea works natively -- NO third-party proxy needed.
#   * The article's env var must be ANTHROPIC_BASE_URL=http://localhost:11434
#     WITHOUT the "/v1" suffix (the "/v1" path is OpenAI-style and is wrong
#     for Claude Code).
#   * `ollama launch claude` is now a real, official command.
#   * On macOS, Ollama installs via Homebrew/.dmg, not the Linux install.sh.
#   * Claude Code needs a large context window (>=64k); we raise it.
#   * Everything runs on localhost: no account, no API key, no cost. Only the
#     one-time install needs internet; usage is fully offline.
#
# Double-click on macOS, or run:  bash setup-claude-ollama.command
# ===========================================================================

set -uo pipefail

# ----------------------------- configuration -------------------------------
# Local coding model (must be a LOCAL model -- no ":cloud" models, which cost
# money and need internet). Override: MODEL="llama3.1:8b" bash setup...command
MODEL="${MODEL:-qwen2.5-coder:7b}"
FALLBACK_MODEL="qwen2.5-coder:3b"          # lighter model if the main one fails
OLLAMA_HOST_URL="http://localhost:11434"   # LOCAL endpoint (note: no "/v1")
CONTEXT_LENGTH="${CONTEXT_LENGTH:-65536}"  # Claude Code needs a large context

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
README_FILE="$SCRIPT_DIR/README.txt"
LOCAL_BIN="$HOME/.local/bin"

# Last-known-good STABLE versions (used only if the live lookup fails). The
# script always prefers the live latest stable; it never uses beta/unstable.
OLLAMA_PINNED_STABLE="v0.21.2"
NVM_PINNED_STABLE="v0.40.1"

# Install manifest: records ONLY what this script installs, so uninstall.command
# can remove exactly that and never touch packages that pre-existed.
STATE_DIR="$HOME/.claude-ollama-setup"
MANIFEST="$STATE_DIR/install-manifest"
DID_INSTALL_HOMEBREW=0; DID_INSTALL_NODE=0; DID_INSTALL_OLLAMA=0; DID_INSTALL_CLAUDE=0
PULLED_MODELS=""

# ------------------------------- logging -----------------------------------
if [ -t 1 ]; then
  BOLD="$(printf '\033[1m')"; RESET="$(printf '\033[0m')"
  RED="$(printf '\033[31m')"; GREEN="$(printf '\033[32m')"
  YELLOW="$(printf '\033[33m')"; BLUE="$(printf '\033[34m')"
else
  BOLD=""; RESET=""; RED=""; GREEN=""; YELLOW=""; BLUE=""
fi
step() { printf "\n%s==>%s %s%s\n" "$BLUE$BOLD" "$RESET$BOLD" "$1" "$RESET"; }
info() { printf "    %s\n" "$1"; }
ok()   { printf "    %s\xE2\x9C\x94%s %s\n" "$GREEN" "$RESET" "$1"; }
warn() { printf "    %s!%s %s\n" "$YELLOW" "$RESET" "$1"; }
err()  { printf "    %s\xE2\x9C\x98%s %s\n" "$RED" "$RESET" "$1" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

# try_each LABEL "cmd1" "cmd2" ... -- run candidates until one succeeds.
# This is the "if one command fails, try an alternative" mechanism.
try_each() {
  local label="$1"; shift
  local cmd n=0 total=$#
  for cmd in "$@"; do
    n=$((n+1))
    info "[$label] attempt $n/$total: $cmd"
    if eval "$cmd"; then ok "$label succeeded (method $n)"; return 0; fi
    warn "[$label] method $n failed."
    [ "$n" -lt "$total" ] && warn "[$label] trying next fallback..."
  done
  err "$label: all $total method(s) failed."
  return 1
}

# retry N CMD -- run CMD up to N times with a short backoff.
retry() {
  local tries="$1"; shift
  local i=1
  while [ "$i" -le "$tries" ]; do
    info "attempt $i/$tries: $*"
    if "$@"; then return 0; fi
    warn "attempt $i failed."
    i=$((i+1)); [ "$i" -le "$tries" ] && sleep 3
  done
  return 1
}

# github_latest_stable OWNER/REPO -- latest STABLE release tag (no beta/rc).
github_latest_stable() {
  local repo="$1" v
  v="$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null \
        | grep -m1 '"tag_name"' \
        | sed -E 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/')"
  if printf '%s' "$v" | grep -Eiq '(rc|beta|alpha|-pre|preview|dev|nightly|snapshot)'; then
    v=""   # never use unstable/beta builds
  fi
  printf '%s' "$v"
}

# Keep the Terminal window open when double-clicked.
finish() {
  local code=$?
  printf "\n"
  if [ "$code" -eq 0 ]; then
    printf "%sDone.%s Press Return to close this window.\n" "$GREEN$BOLD" "$RESET"
  else
    printf "%sExited with status %s.%s Press Return to close this window.\n" "$RED$BOLD" "$code" "$RESET"
  fi
  [ -t 0 ] && { read -r _ || true; }
}
trap finish EXIT

# --------------------------- OS / arch detection ---------------------------
step "Detecting operating system and architecture"
OS="$(uname -s)"; ARCH="$(uname -m)"; PLATFORM=""
case "$OS" in
  Darwin) PLATFORM="macos" ;;
  Linux)  PLATFORM="linux" ;;
  *) err "Unsupported OS: $OS (macOS and Linux only)."; exit 1 ;;
esac
ok "OS: $OS ($PLATFORM), architecture: $ARCH"

LINUX_PKG=""
if [ "$PLATFORM" = "linux" ]; then
  if   have apt-get; then LINUX_PKG="apt"
  elif have dnf;     then LINUX_PKG="dnf"
  elif have yum;     then LINUX_PKG="yum"
  elif have pacman;  then LINUX_PKG="pacman"
  elif have zypper;  then LINUX_PKG="zypper"
  fi
  [ -n "$LINUX_PKG" ] && ok "Package manager: $LINUX_PKG" || warn "No known package manager; some installs may need manual steps."
fi
SUDO=""; { [ "$(id -u)" -ne 0 ] && have sudo; } && SUDO="sudo"

# Zero-cost / offline guard: reject Ollama "cloud" models.
if printf '%s' "$MODEL" | grep -qi ':cloud'; then
  warn "'$MODEL' is a CLOUD model (needs internet + account; not free/offline)."
  MODEL="qwen2.5-coder:7b"
  warn "Using local model '$MODEL' instead to keep this offline and zero-cost."
fi

# ============================ PREFLIGHT (phase 1) ==========================
# Confirm what is already installed, install anything missing, then re-confirm
# EVERYTHING before the setup proceeds.
step "Preflight scan -- checking what is already installed"
if have curl; then ok "curl present"; else
  err "curl is required and missing. Install curl and re-run."; exit 1; fi

# RAM / disk advisories (warn only).
RAM_GB=""
if [ "$PLATFORM" = "macos" ]; then
  RAM_GB=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 / 1024 ))
elif [ -r /proc/meminfo ]; then
  RAM_GB=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 / 1024 ))
fi
if [ -n "$RAM_GB" ] && [ "$RAM_GB" -gt 0 ]; then
  [ "$RAM_GB" -ge 8 ] && ok "RAM: ${RAM_GB} GB" \
    || warn "RAM: ${RAM_GB} GB -- a 7B model wants ~6-8 GB free. Consider MODEL=qwen2.5-coder:3b."
fi
if have df; then
  FREE_HUMAN="$(df -h "$HOME" 2>/dev/null | awk 'NR==2{print $4}')"
  [ -n "$FREE_HUMAN" ] && info "Free space in \$HOME: $FREE_HUMAN (model is ~4-5 GB)"
fi

have brew   && [ "$PLATFORM" = "macos" ] && ok "Homebrew present" || true
have node   && ok "Node present ($(node -v))"   || warn "Node.js missing -- will install."
have npm    && ok "npm present ($(npm -v))"     || warn "npm missing -- comes with Node.js."
have ollama && ok "Ollama present ($(ollama -v 2>/dev/null | head -n1))" || warn "Ollama missing -- will install."

if [ -t 0 ]; then
  printf "\n%sThis installs (if missing): Ollama, Node.js, Claude Code, and pulls local model '%s'. All free & local.%s\n" "$BOLD" "$MODEL" "$RESET"
  printf "Continue? [Y/n] "
  read -r REPLY || REPLY="y"
  case "$REPLY" in [nN]*) info "Aborted."; exit 0 ;; esac
fi

# ------------------- resolve latest STABLE versions ------------------------
step "Resolving latest stable versions (never beta/unstable)"
OLLAMA_VER="$(github_latest_stable ollama/ollama)"
[ -n "$OLLAMA_VER" ] && ok "Ollama latest stable: $OLLAMA_VER" \
  || { OLLAMA_VER="$OLLAMA_PINNED_STABLE"; warn "Lookup failed; using pinned stable $OLLAMA_VER"; }
NVM_VER="$(github_latest_stable nvm-sh/nvm)"
[ -n "$NVM_VER" ] && ok "nvm latest stable: $NVM_VER" \
  || { NVM_VER="$NVM_PINNED_STABLE"; warn "Lookup failed; using pinned stable $NVM_VER"; }
OLLAMA_VER_NUM="${OLLAMA_VER#v}"; OLLAMA_PINNED_NUM="${OLLAMA_PINNED_STABLE#v}"

# --------------------------- install Homebrew (mac) ------------------------
if [ "$PLATFORM" = "macos" ] && ! have brew; then
  step "Installing Homebrew"
  try_each "Homebrew install" \
    'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"' \
    '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"' \
    || { err "Homebrew install failed. See https://brew.sh"; exit 1; }
  if   [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [ -x /usr/local/bin/brew ];    then eval "$(/usr/local/bin/brew shellenv)"; fi
  have brew && { DID_INSTALL_HOMEBREW=1; ok "Homebrew installed"; } || { err "brew not on PATH."; exit 1; }
fi

# ------------------------------ install Node -------------------------------
if ! have node || ! have npm; then
  step "Installing Node.js (LTS)"
  NVM_INSTALL="(curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VER/install.sh || curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_PINNED_STABLE/install.sh) | bash && export NVM_DIR=\"\$HOME/.nvm\" && . \"\$NVM_DIR/nvm.sh\" && nvm install --lts && nvm use --lts"
  if [ "$PLATFORM" = "macos" ]; then
    try_each "Node install" \
      "brew install node" \
      "brew install node@22 && brew link --overwrite --force node@22" \
      "$NVM_INSTALL"
  else
    case "$LINUX_PKG" in
      apt)    try_each "Node install" \
                "curl -fsSL https://deb.nodesource.com/setup_lts.x | $SUDO -E bash - && $SUDO apt-get install -y nodejs" \
                "$SUDO apt-get update && $SUDO apt-get install -y nodejs npm" \
                "$NVM_INSTALL" ;;
      dnf)    try_each "Node install" "$SUDO dnf install -y nodejs npm" "$NVM_INSTALL" ;;
      yum)    try_each "Node install" \
                "curl -fsSL https://rpm.nodesource.com/setup_lts.x | $SUDO bash - && $SUDO yum install -y nodejs" \
                "$SUDO yum install -y nodejs npm" "$NVM_INSTALL" ;;
      pacman) try_each "Node install" "$SUDO pacman -Sy --noconfirm nodejs npm" "$NVM_INSTALL" ;;
      zypper) try_each "Node install" "$SUDO zypper install -y nodejs npm" "$NVM_INSTALL" ;;
      *)      try_each "Node install" "$NVM_INSTALL" ;;
    esac
  fi
  [ -s "$HOME/.nvm/nvm.sh" ] && { export NVM_DIR="$HOME/.nvm"; . "$HOME/.nvm/nvm.sh"; }
  have node && { DID_INSTALL_NODE=1; ok "Node installed ($(node -v))"; } \
    || { err "Node install failed. Install Node >= 18 from https://nodejs.org and re-run."; exit 1; }
fi
NPM_BIN="$(npm prefix -g 2>/dev/null)/bin"
case ":$PATH:" in *":$NPM_BIN:"*) : ;; *) [ -d "$NPM_BIN" ] && export PATH="$NPM_BIN:$PATH" ;; esac

# ----------------------------- install Ollama ------------------------------
if ! have ollama; then
  step "Installing Ollama ($OLLAMA_VER)"
  if [ "$PLATFORM" = "macos" ]; then
    dmg_install() {  # $1 = release tag
      local tag="$1"
      curl -fsSL -o /tmp/Ollama.dmg "https://github.com/ollama/ollama/releases/download/$tag/Ollama.dmg" \
        && hdiutil attach /tmp/Ollama.dmg -nobrowse -quiet \
        && cp -R "/Volumes/Ollama/Ollama.app" /Applications/ \
        && hdiutil detach "/Volumes/Ollama" -quiet \
        && open -a Ollama \
        && { ln -sf /Applications/Ollama.app/Contents/Resources/ollama /usr/local/bin/ollama 2>/dev/null || true; } \
        && { command -v ollama >/dev/null 2>&1 || [ -x /Applications/Ollama.app/Contents/Resources/ollama ]; }
    }
    try_each "Ollama install" \
      "brew install ollama" \
      "brew install --cask ollama" \
      "dmg_install $OLLAMA_VER" \
      "dmg_install $OLLAMA_PINNED_STABLE" \
      || { err "Ollama install failed. See https://ollama.com/download"; exit 1; }
    if ! have ollama && [ -x /Applications/Ollama.app/Contents/Resources/ollama ]; then
      export PATH="/Applications/Ollama.app/Contents/Resources:$PATH"
    fi
  else
    # Linux install.sh honors OLLAMA_VERSION: latest stable -> pinned -> default.
    try_each "Ollama install" \
      "curl -fsSL https://ollama.com/install.sh | OLLAMA_VERSION=$OLLAMA_VER_NUM sh" \
      "curl -fsSL https://ollama.com/install.sh | OLLAMA_VERSION=$OLLAMA_VER_NUM $SUDO sh" \
      "curl -fsSL https://ollama.com/install.sh | OLLAMA_VERSION=$OLLAMA_PINNED_NUM sh" \
      "curl -fsSL https://ollama.com/install.sh | sh" \
      || { err "Ollama install failed. See https://ollama.com/download/linux"; exit 1; }
  fi
  have ollama && { DID_INSTALL_OLLAMA=1; ok "Ollama installed ($(ollama -v 2>/dev/null | head -n1))"; } || { err "Ollama install failed."; exit 1; }
fi

# --------------------------- install Claude Code ---------------------------
# Article steps 2+3 ("Install Claude CLI" and "Install Claude Code") are the
# same product: @anthropic-ai/claude-code.
if ! have claude; then
  step "Installing Claude Code"
  DID_INSTALL_CLAUDE=1
  try_each "Claude Code install" \
    "npm install -g @anthropic-ai/claude-code" \
    "$SUDO npm install -g @anthropic-ai/claude-code" \
    "npm install -g @anthropic-ai/claude-code --unsafe-perm" \
    "curl -fsSL https://claude.ai/install.sh | bash" \
    "curl -fsSL https://code.claude.com/install.sh | bash" \
    || { err "Claude Code install failed. See https://code.claude.com/docs/en/quickstart"; }
  # Claude Code's standalone installer drops the binary in ~/.local/bin.
  case ":$PATH:" in *":$LOCAL_BIN:"*) : ;; *) [ -d "$LOCAL_BIN" ] && export PATH="$LOCAL_BIN:$PATH" ;; esac
  NPM_BIN="$(npm prefix -g 2>/dev/null)/bin"
  case ":$PATH:" in *":$NPM_BIN:"*) : ;; *) [ -d "$NPM_BIN" ] && export PATH="$NPM_BIN:$PATH" ;; esac
fi

# ===================== PREFLIGHT GATE (confirm before setup) ===============
step "Preflight gate -- confirming all prerequisites are installed"
GATE_FAIL=0
confirm_req() {  # $1 name  $2 binary  $3 version
  if have "$2"; then ok "$1 confirmed${3:+ ($3)}"
  else err "$1 STILL missing after install attempts."; GATE_FAIL=$((GATE_FAIL+1)); fi
}
confirm_req "curl"        curl   "$(curl --version 2>/dev/null | head -n1 | awk '{print $1,$2}')"
confirm_req "Node.js"     node   "$(node -v 2>/dev/null)"
confirm_req "npm"         npm    "$(npm -v 2>/dev/null)"
confirm_req "Ollama"      ollama "$(ollama -v 2>/dev/null | head -n1)"
confirm_req "Claude Code" claude ""
if [ "$GATE_FAIL" -gt 0 ]; then
  err "Preflight FAILED: $GATE_FAIL prerequisite(s) not confirmed. Setup will not continue."
  exit 1
fi
ok "Preflight passed -- all prerequisites installed and confirmed."

# ------------------- start the Ollama server (large context) ---------------
step "Starting the Ollama server (context length: $CONTEXT_LENGTH)"
export OLLAMA_CONTEXT_LENGTH="$CONTEXT_LENGTH"
[ "$PLATFORM" = "macos" ] && { launchctl setenv OLLAMA_CONTEXT_LENGTH "$CONTEXT_LENGTH" 2>/dev/null || true; }
if curl -fsS "$OLLAMA_HOST_URL/api/tags" >/dev/null 2>&1; then
  ok "Ollama already running at $OLLAMA_HOST_URL"
else
  [ "$PLATFORM" = "macos" ] && have brew && { brew services start ollama >/dev/null 2>&1 || true; }
  curl -fsS "$OLLAMA_HOST_URL/api/tags" >/dev/null 2>&1 || \
    OLLAMA_CONTEXT_LENGTH="$CONTEXT_LENGTH" nohup ollama serve >/tmp/ollama-serve.log 2>&1 &
  for _ in $(seq 1 30); do curl -fsS "$OLLAMA_HOST_URL/api/tags" >/dev/null 2>&1 && break; sleep 1; done
  curl -fsS "$OLLAMA_HOST_URL/api/tags" >/dev/null 2>&1 \
    && ok "Ollama server is up at $OLLAMA_HOST_URL" \
    || warn "Could not confirm Ollama is running. Check /tmp/ollama-serve.log"
fi

# ----------------------------- pull the model ------------------------------
step "Pulling local coding model: $MODEL"
if ollama list 2>/dev/null | awk '{print $1}' | grep -qx "$MODEL"; then
  ok "Model '$MODEL' already present"
elif retry 3 ollama pull "$MODEL"; then
  ok "Model '$MODEL' pulled"; PULLED_MODELS="$MODEL"
else
  warn "Could not pull '$MODEL' after 3 tries. Trying lighter local model '$FALLBACK_MODEL'..."
  if [ "$MODEL" != "$FALLBACK_MODEL" ] && retry 2 ollama pull "$FALLBACK_MODEL"; then
    MODEL="$FALLBACK_MODEL"; ok "Fell back to '$MODEL'."; PULLED_MODELS="$FALLBACK_MODEL"
  else
    warn "No model pulled. Pull one later with: ollama pull $MODEL"
  fi
fi

# ------------------- optional: add a second local model --------------------
# Offer a stronger alternative now so the user can switch between them later
# with:  claude-local -m <model>
ALT_MODEL="deepseek-coder-v2:16b"
if [ -t 0 ] && ! ollama list 2>/dev/null | awk '{print $1}' | grep -qx "$ALT_MODEL"; then
  printf "\n    Also download a second, stronger local model '%s' now? (needs ~10 GB RAM) [y/N] " "$ALT_MODEL"
  read -r ALT_REPLY || ALT_REPLY="n"
  case "$ALT_REPLY" in
    [yY]*) retry 2 ollama pull "$ALT_MODEL" \
             && { ok "Added '$ALT_MODEL'."; PULLED_MODELS="$PULLED_MODELS $ALT_MODEL"; } \
             || warn "Could not pull '$ALT_MODEL'. Add it later: ollama pull $ALT_MODEL" ;;
    *)     info "Skipped. Add it any time:  ollama pull $ALT_MODEL" ;;
  esac
fi

# ============== CONFIGURE ENVIRONMENT (article step 5, corrected) ==========
# The article adds env vars to ~/.bashrc / ~/.zshrc and reloads. We do the
# same -- corrected URL (no "/v1") and with offline/zero-cost flags so Claude
# Code uses the LOCAL model and makes no external/telemetry calls.
step "Creating the 'claude-local' launcher (env baked in, no manual setup)"
# Instead of editing the shell profile (fragile), we install a small launcher
# that bakes in the offline env vars and execs Claude Code. The user just runs
# 'claude-local' -- nothing to type, nothing to add to ~/.zshrc.
mkdir -p "$LOCAL_BIN"
# Prefer installing next to the 'claude' binary (already on PATH); fall back to
# ~/.local/bin and add that to PATH.
CLAUDE_PATH="$(command -v claude 2>/dev/null || true)"
if [ -n "$CLAUDE_PATH" ] && [ -w "$(dirname "$CLAUDE_PATH")" ]; then
  LAUNCHER_DIR="$(dirname "$CLAUDE_PATH")"
else
  LAUNCHER_DIR="$LOCAL_BIN"
fi
LAUNCHER="$LAUNCHER_DIR/claude-local"
cat > "$LAUNCHER" <<EOF
#!/usr/bin/env bash
# Run Claude Code on a LOCAL Ollama model -- offline, zero cost.
# Env vars are baked in so you never type them or edit your shell profile.
#
# Pick the model at startup (default below) in any of these ways:
#   claude-local                              # default model
#   claude-local -m deepseek-coder-v2:16b     # pick a model for this run
#   CCMODEL=deepseek-coder-v2:16b claude-local
# Extra args pass straight to Claude Code, e.g.:
#   claude-local -m deepseek-coder-v2:16b --append-system-prompt-file system-prompt-local-offline.md
# Created by setup-claude-ollama.command.
export ANTHROPIC_BASE_URL="$OLLAMA_HOST_URL"   # localhost, NO /v1
export ANTHROPIC_AUTH_TOKEN="ollama"           # dummy token (local)
export ANTHROPIC_API_KEY=""
export OLLAMA_CONTEXT_LENGTH="$CONTEXT_LENGTH"
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1"
export DISABLE_TELEMETRY="1"
export DISABLE_ERROR_REPORTING="1"
export DISABLE_AUTOUPDATER="1"
export DISABLE_COST_WARNINGS="1"
# Choose model: -m/--model first arg wins, else \$CCMODEL, else the default.
MODEL="\${CCMODEL:-$MODEL}"
if [ "\$1" = "-m" ] || [ "\$1" = "--model" ]; then MODEL="\$2"; shift 2; fi
exec claude --model "\$MODEL" "\$@"
EOF
chmod +x "$LAUNCHER"
ok "Created launcher: $LAUNCHER"

# Only touch the shell profile if the launcher dir isn't already on PATH, and
# only to add PATH (no env exports there). Idempotent via markers.
case ":$PATH:" in
  *":$LAUNCHER_DIR:"*) ok "$LAUNCHER_DIR already on PATH" ;;
  *)
    case "$(basename "${SHELL:-}")" in
      zsh)  SHELL_RC="$HOME/.zshrc" ;;
      bash) [ "$PLATFORM" = "macos" ] && SHELL_RC="$HOME/.bash_profile" || SHELL_RC="$HOME/.bashrc" ;;
      *)    SHELL_RC="$HOME/.profile" ;;
    esac
    touch "$SHELL_RC" 2>/dev/null || true
    MARK_START="# >>> setup-claude-ollama >>>"; MARK_END="# <<< setup-claude-ollama <<<"
    if grep -qF "$MARK_START" "$SHELL_RC" 2>/dev/null; then
      tmp="$(mktemp)"; awk -v s="$MARK_START" -v e="$MARK_END" '
        $0==s{skip=1} !skip{print} $0==e{skip=0}' "$SHELL_RC" > "$tmp" && mv "$tmp" "$SHELL_RC"
    fi
    printf '%s\nexport PATH="%s:$PATH"\n%s\n' "$MARK_START" "$LAUNCHER_DIR" "$MARK_END" >> "$SHELL_RC"
    export PATH="$LAUNCHER_DIR:$PATH"
    ok "Added $LAUNCHER_DIR to PATH in $SHELL_RC"
    ;;
esac

# Apply env to THIS session so verification works immediately.
export ANTHROPIC_BASE_URL="$OLLAMA_HOST_URL"
export ANTHROPIC_AUTH_TOKEN="ollama"
export ANTHROPIC_API_KEY=""
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1"
export DISABLE_TELEMETRY="1" DISABLE_ERROR_REPORTING="1" DISABLE_AUTOUPDATER="1" DISABLE_COST_WARNINGS="1"

# --------------------------- write install manifest ------------------------
step "Recording install manifest (for clean uninstall)"
mkdir -p "$STATE_DIR"
yn() { [ "$1" = 1 ] && echo yes || echo no; }
{
  echo "# Records ONLY what setup-claude-ollama.command installed."
  echo "# uninstall.command uses this to avoid removing pre-existing packages."
  echo "DATE=$(date)"
  echo "PLATFORM=$PLATFORM"
  echo "INSTALLED_HOMEBREW=$(yn "$DID_INSTALL_HOMEBREW")"
  echo "INSTALLED_NODE=$(yn "$DID_INSTALL_NODE")"
  echo "INSTALLED_OLLAMA=$(yn "$DID_INSTALL_OLLAMA")"
  echo "INSTALLED_CLAUDE_CODE=$(yn "$DID_INSTALL_CLAUDE")"
  echo "PULLED_MODELS=$(echo $PULLED_MODELS | xargs)"
  echo "LAUNCHER=$LAUNCHER"
  echo "SHELL_RC=${SHELL_RC:-}"
} > "$MANIFEST"
ok "Manifest written to $MANIFEST"

# --------------------------- generate README.txt ---------------------------
step "Generating README.txt"
cat > "$README_FILE" <<EOF
================================================================================
 RUN CLAUDE CODE FOR FREE, LOCALLY  (Ollama + Claude Code)
 Zero cost  -  fully offline  -  local-only
 Generated by setup-claude-ollama.command on $(date)
================================================================================

This follows the dev.to article "Run Claude for FREE Locally (Using Ollama +
Claude Code)", corrected so every step actually works. Everything runs on your
own machine: NO account, NO API key, NO cost. The only endpoint Claude Code
talks to is your LOCAL Ollama server at $OLLAMA_HOST_URL. Installation needs
internet; after that you can use it offline.

WHAT WAS INSTALLED
--------------------------------------------------------------------------------
  - Ollama .................. local LLM engine ($OLLAMA_HOST_URL)
  - Model ................... $MODEL   (local; runs on your hardware)
  - Node.js / npm ........... runtime for Claude Code
  - Claude Code ............. the coding CLI ("claude")
  - claude-local ............ launcher with the offline env vars baked in:
                              $LAUNCHER

HOW TO USE IT  (just run claude-local)
--------------------------------------------------------------------------------
1. Make sure Ollama is running (it usually starts on its own):
       ollama serve            # only if it is not already running

2. Start coding on your local model:
       claude-local

   That's it. 'claude-local' sets ANTHROPIC_BASE_URL=$OLLAMA_HOST_URL and the
   offline flags for you, then runs Claude Code on '$MODEL'. No env vars to
   type, nothing to add to your shell profile. Everything runs locally -- no
   account, no API key, no cost.

   (If you ever see "command not found: claude-local", open a NEW terminal so
   PATH updates, or run it by full path: $LAUNCHER)

SWITCH SYSTEM PROMPT FILES
--------------------------------------------------------------------------------
claude-local passes any extra arguments straight to Claude Code, so:
  claude-local --append-system-prompt-file system-prompt-local-offline.md
  claude-local --append-system-prompt-file CLAUDE-FABLE-5.md
  claude-local                                  # no custom prompt
(Run from the folder that contains the prompt file. Use --append-system-prompt-
file, not --system-prompt-file, which would break Claude Code's editing.)

EVERYDAY COMMANDS
--------------------------------------------------------------------------------
  claude-local             Start Claude Code on your local model (offline)
  claude-local -p "..."    One-shot prompt, print result, exit
  claude --help            Claude Code help

  ollama list              List installed (local) models
  ollama pull <model>      Download another LOCAL model
  ollama run <model>       Chat with a model directly in the terminal
  ollama ps                Show running models
  ollama rm <model>        Remove a model
  ollama -v                Ollama version

SWITCH OR ADD LOCAL MODELS  (all free, all offline)
--------------------------------------------------------------------------------
  ollama pull deepseek-coder-v2:16b     # bigger/stronger (needs more RAM)
  ollama pull qwen2.5-coder:3b          # smaller/lighter
Use another model for one run:  claude-local --model <model>
To change the default, edit the --model line in: $LAUNCHER
Good local coding models:
  qwen2.5-coder:7b (default)  qwen2.5-coder:3b / :14b / :32b
  deepseek-coder-v2:16b       codellama:13b       llama3.1:8b
AVOID any "<name>:cloud" model -- those run on Ollama's servers (cost + online).

CONTEXT LENGTH
--------------------------------------------------------------------------------
Claude Code needs a large context window (>= 64k tokens). claude-local sets
OLLAMA_CONTEXT_LENGTH=$CONTEXT_LENGTH. If answers get cut off, raise it in the
launcher and restart Ollama.

TROUBLESHOOTING
--------------------------------------------------------------------------------
  - "command not found: claude-local"
        Open a NEW terminal, or run the full path: $LAUNCHER
  - "API error / retrying" or "connection refused"
        You probably ran plain 'claude' (which tries the hosted API) instead of
        'claude-local'. Use claude-local. Also confirm Ollama is up:
        curl $OLLAMA_HOST_URL/api/tags   (start it with: ollama serve)
  - Slow / lower-quality answers
        Local models are smaller than hosted Claude. Try a larger local model.
  - Safe to re-run this installer any time (idempotent).

OFFICIAL DOCS / CLI REFERENCES
--------------------------------------------------------------------------------
  Claude Code quickstart .... https://code.claude.com/docs/en/quickstart
  Claude Code CLI reference . https://code.claude.com/docs/en/cli-reference
  Ollama + Claude Code ...... https://docs.ollama.com/integrations/claude-code
  Ollama docs / CLI ......... https://docs.ollama.com
  Ollama model library ...... https://ollama.com/library
  Original article .......... https://dev.to/tj1609/run-claude-for-free-locally-using-ollama-claude-code-45lf
================================================================================
EOF
ok "README.txt written to $README_FILE"

# ------------------------------ verification -------------------------------
step "Verifying installation"
have ollama       && ok "ollama: $(ollama -v 2>/dev/null | head -n1)" || warn "ollama not on PATH"
have node         && ok "node:   $(node -v)" || warn "node not on PATH"
have claude       && ok "claude: present"    || warn "claude not on PATH (open a new terminal)"
[ -x "$LAUNCHER" ] && ok "claude-local launcher: $LAUNCHER" || warn "launcher not found"
if ollama list 2>/dev/null | awk '{print $1}' | grep -qx "$MODEL"; then ok "model:  $MODEL ready (local)"; else warn "model $MODEL not confirmed"; fi
if curl -fsS "$OLLAMA_HOST_URL/api/tags" >/dev/null 2>&1; then
  ok "Local Ollama API reachable at $OLLAMA_HOST_URL (offline)"
else
  warn "Local Ollama API not reachable -- start it with: ollama serve"
fi

# -------------------------------- summary ----------------------------------
step "All set -- zero cost, fully offline, local-only"
printf "    %sOpen a NEW terminal, then just run:%s\n\n" "$BOLD" "$RESET"
printf "        %sclaude-local%s\n\n" "$GREEN$BOLD" "$RESET"
printf "    With a custom system prompt:\n"
printf "        %sclaude-local --append-system-prompt-file system-prompt-local-offline.md%s\n\n" "$GREEN$BOLD" "$RESET"
printf "    No env vars to type, no shell edits -- everything is baked into the\n"
printf "    launcher and runs on localhost (no account, no API key, no cost).\n"
printf "    Full instructions: %s\n" "$README_FILE"
