#!/usr/bin/env bash
#
# uninstall.command
# ===========================================================================
# Reverses setup-claude-ollama.command. It removes ONLY what the setup
# installed -- it never removes packages that existed on your system before.
#
# How it knows the difference: the setup writes a manifest at
#   ~/.claude-ollama-setup/install-manifest
# recording which of Homebrew/Node/Ollama/Claude Code it installed (yes/no)
# and which models it pulled. This uninstaller removes only the "yes" items
# and the pulled models. Anything marked "no" pre-existed and is left alone.
#
# If no manifest is found (e.g. installed before manifests existed), it asks
# about each item and DEFAULTS TO NOT removing shared tools, to stay safe.
#
# It does NOT delete your own files (the setup script, README, prompt files,
# or any project/code you created).
#
# Double-click on macOS, or run:  bash uninstall.command
# ===========================================================================

set -uo pipefail

STATE_DIR="$HOME/.claude-ollama-setup"
MANIFEST="$STATE_DIR/install-manifest"
LOCAL_BIN="$HOME/.local/bin"
MARK_START="# >>> setup-claude-ollama >>>"
MARK_END="# <<< setup-claude-ollama <<<"

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
ask()  { # $1 = prompt; returns 0 for yes. Default NO.
  local r; printf "    %s [y/N] " "$1"; read -r r </dev/tty 2>/dev/null || r="n"
  case "$r" in [yY]*) return 0 ;; *) return 1 ;; esac
}

finish() {
  local code=$?
  printf "\n"
  [ "$code" -eq 0 ] && printf "%sUninstall finished.%s Press Return to close.\n" "$GREEN$BOLD" "$RESET" \
                    || printf "%sExited with status %s.%s Press Return to close.\n" "$RED$BOLD" "$code" "$RESET"
  [ -t 0 ] && { read -r _ || true; }
}
trap finish EXIT

OS="$(uname -s)"; PLATFORM="other"
[ "$OS" = "Darwin" ] && PLATFORM="macos"; [ "$OS" = "Linux" ] && PLATFORM="linux"
SUDO=""; { [ "$(id -u)" -ne 0 ] && have sudo; } && SUDO="sudo"

# --------------------------- load the manifest -----------------------------
step "Looking for the install manifest"
M_HOMEBREW=""; M_NODE=""; M_OLLAMA=""; M_CLAUDE=""; M_MODELS=""; M_LAUNCHER=""; M_RC=""
MANIFEST_FOUND=0
if [ -f "$MANIFEST" ]; then
  MANIFEST_FOUND=1
  # shellcheck disable=SC1090
  while IFS='=' read -r k v; do
    case "$k" in
      INSTALLED_HOMEBREW)    M_HOMEBREW="$v" ;;
      INSTALLED_NODE)        M_NODE="$v" ;;
      INSTALLED_OLLAMA)      M_OLLAMA="$v" ;;
      INSTALLED_CLAUDE_CODE) M_CLAUDE="$v" ;;
      PULLED_MODELS)         M_MODELS="$v" ;;
      LAUNCHER)              M_LAUNCHER="$v" ;;
      SHELL_RC)              M_RC="$v" ;;
    esac
  done < "$MANIFEST"
  ok "Manifest found: $MANIFEST"
  info "Will remove only what the setup installed; anything marked 'no' is left alone."
else
  warn "No manifest found. Switching to SAFE mode: you'll be asked about each"
  warn "item, defaulting to NOT removing shared tools (in case they pre-existed)."
fi

# decide MANIFEST_VALUE "prompt"  -> 0 = remove, 1 = keep
decide() {
  case "$1" in
    yes) return 0 ;;
    no)  info "Kept (pre-existed before setup): ${2#Remove }"; return 1 ;;
    *)   ask "$2" ;;
  esac
}

printf "\n%sThis will uninstall the local Claude Code + Ollama setup.%s\n" "$BOLD" "$RESET"
if [ -t 0 ]; then
  ask "Continue?" || { info "Aborted."; exit 0; }
fi

# --------------------- 1. remove the claude-local launcher -----------------
step "Removing the claude-local launcher"
removed_launcher=0
for f in "$M_LAUNCHER" "$LOCAL_BIN/claude-ollama" "$LOCAL_BIN/claude-local"; do
  [ -n "$f" ] && [ -f "$f" ] && { rm -f "$f" && ok "Removed $f" && removed_launcher=1; }
done
# Also check next to the claude binary.
if have claude; then
  cdir="$(dirname "$(command -v claude)")"
  [ -f "$cdir/claude-local" ] && { rm -f "$cdir/claude-local" && ok "Removed $cdir/claude-local" && removed_launcher=1; }
fi
[ "$removed_launcher" = 0 ] && info "No launcher found."

# --------------------- 2. remove shell-profile block -----------------------
step "Removing PATH/env block from shell profile(s)"
rc_list="$M_RC $HOME/.zshrc $HOME/.bashrc $HOME/.bash_profile $HOME/.profile"
cleaned=0
for rc in $rc_list; do
  [ -n "$rc" ] && [ -f "$rc" ] || continue
  if grep -qF "$MARK_START" "$rc" 2>/dev/null; then
    tmp="$(mktemp)"
    awk -v s="$MARK_START" -v e="$MARK_END" '$0==s{skip=1} !skip{print} $0==e{skip=0}' "$rc" > "$tmp" && mv "$tmp" "$rc"
    ok "Cleaned setup block from $rc"; cleaned=1
  fi
done
[ "$cleaned" = 0 ] && info "No setup block found in shell profiles."

# --------------------- 3. stop Ollama (so we can remove it) -----------------
step "Stopping the Ollama server"
if [ "$PLATFORM" = "macos" ]; then
  have brew && brew services stop ollama >/dev/null 2>&1 || true
  osascript -e 'quit app "Ollama"' >/dev/null 2>&1 || true
  launchctl unsetenv OLLAMA_CONTEXT_LENGTH 2>/dev/null || true
elif [ "$PLATFORM" = "linux" ]; then
  $SUDO systemctl stop ollama >/dev/null 2>&1 || true
fi
pkill -f "ollama serve" >/dev/null 2>&1 || true
ok "Ollama stopped (if it was running)."

# --------------------- 4. remove models the setup pulled -------------------
step "Removing models that the setup downloaded"
if have ollama; then
  if [ "$MANIFEST_FOUND" = 1 ]; then
    if [ -n "$(echo "$M_MODELS" | xargs 2>/dev/null)" ]; then
      for m in $M_MODELS; do
        ollama rm "$m" >/dev/null 2>&1 && ok "Removed model $m" || warn "Could not remove model $m"
      done
    else
      info "Manifest shows no models were pulled by setup; leaving models alone."
    fi
  else
    info "No manifest. Installed models:"; ollama list 2>/dev/null | sed 's/^/      /'
    for m in qwen2.5-coder:7b qwen2.5-coder:3b deepseek-coder-v2:16b; do
      if ollama list 2>/dev/null | awk '{print $1}' | grep -qx "$m"; then
        ask "Remove model $m? (only if setup added it)" && \
          { ollama rm "$m" >/dev/null 2>&1 && ok "Removed $m" || warn "Failed to remove $m"; }
      fi
    done
  fi
else
  info "ollama not on PATH; skipping model removal."
fi

# --------------------- 5. remove Claude Code -------------------------------
step "Claude Code"
if decide "$M_CLAUDE" "Remove Claude Code (the 'claude' CLI)?"; then
  if have npm; then npm uninstall -g @anthropic-ai/claude-code >/dev/null 2>&1 \
       && ok "Uninstalled @anthropic-ai/claude-code (npm)" \
       || { $SUDO npm uninstall -g @anthropic-ai/claude-code >/dev/null 2>&1 \
            && ok "Uninstalled (sudo)" || warn "npm uninstall did not report success"; }
  fi
  # Standalone installer drops a binary in ~/.local/bin.
  [ -f "$LOCAL_BIN/claude" ] && { rm -f "$LOCAL_BIN/claude" && ok "Removed $LOCAL_BIN/claude"; }
  if ask "Also remove Claude Code config/sessions (~/.claude, ~/.claude.json)? This deletes session history."; then
    rm -rf "$HOME/.claude" "$HOME/.claude.json" 2>/dev/null && ok "Removed Claude Code config." || true
  fi
fi
# Clean up any leftover claude-code-router config from older setups.
[ -d "$HOME/.claude-code-router" ] && ask "Remove leftover ~/.claude-code-router?" && \
  { rm -rf "$HOME/.claude-code-router" && ok "Removed ~/.claude-code-router"; }

# --------------------- 6. remove Ollama -----------------------------------
step "Ollama"
remove_ollama() {
  if [ "$PLATFORM" = "macos" ]; then
    if have brew && brew list --formula ollama >/dev/null 2>&1; then
      brew uninstall ollama >/dev/null 2>&1 && ok "brew uninstall ollama" || warn "brew uninstall failed"
    elif have brew && brew list --cask ollama >/dev/null 2>&1; then
      brew uninstall --cask ollama >/dev/null 2>&1 && ok "brew uninstall --cask ollama" || warn "cask uninstall failed"
    fi
    [ -d "/Applications/Ollama.app" ] && { rm -rf "/Applications/Ollama.app" && ok "Removed /Applications/Ollama.app"; }
    [ -L "/usr/local/bin/ollama" ] || [ -f "/usr/local/bin/ollama" ] && { $SUDO rm -f /usr/local/bin/ollama && ok "Removed /usr/local/bin/ollama"; }
  else
    $SUDO systemctl disable ollama >/dev/null 2>&1 || true
    $SUDO rm -f /etc/systemd/system/ollama.service 2>/dev/null || true
    obin="$(command -v ollama 2>/dev/null)"; [ -n "$obin" ] && { $SUDO rm -f "$obin" && ok "Removed $obin"; }
    $SUDO rm -rf /usr/share/ollama 2>/dev/null || true
    $SUDO userdel ollama >/dev/null 2>&1 || true
    $SUDO groupdel ollama >/dev/null 2>&1 || true
    ok "Removed Ollama (Linux)."
  fi
}
if decide "$M_OLLAMA" "Remove Ollama (the local LLM engine)?"; then
  remove_ollama
  if ask "Also delete downloaded models + Ollama data (~/.ollama)? Frees disk; cannot be undone."; then
    rm -rf "$HOME/.ollama" 2>/dev/null && ok "Removed ~/.ollama" || true
  fi
else
  info "Leaving Ollama installed."
fi

# --------------------- 7. Node (only if setup installed it) ----------------
step "Node.js"
if decide "$M_NODE" "Remove Node.js? (only if setup installed it; may affect other projects)"; then
  if [ "$PLATFORM" = "macos" ] && have brew && brew list --formula node >/dev/null 2>&1; then
    brew uninstall node >/dev/null 2>&1 && ok "brew uninstall node" || warn "Could not brew uninstall node"
  elif [ -d "$HOME/.nvm" ]; then
    ask "Remove nvm and its Node versions (~/.nvm)?" && { rm -rf "$HOME/.nvm" && ok "Removed ~/.nvm"; }
  else
    warn "Node was installed via your OS package manager. Remove manually if desired:"
    info "  apt: sudo apt-get remove nodejs    dnf: sudo dnf remove nodejs    etc."
  fi
fi

# --------------------- 8. Homebrew (extra-careful) -------------------------
if [ "$M_HOMEBREW" = "yes" ]; then
  step "Homebrew (installed by setup)"
  warn "Uninstalling Homebrew removes ALL Homebrew packages, not just these."
  if ask "Uninstall Homebrew completely?"; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh)" \
      && ok "Homebrew uninstalled" || warn "Homebrew uninstaller did not finish."
  else
    info "Leaving Homebrew installed."
  fi
fi

# --------------------- 9. remove the state dir -----------------------------
step "Cleaning up setup state"
[ -d "$STATE_DIR" ] && { rm -rf "$STATE_DIR" && ok "Removed $STATE_DIR"; } || info "No state dir."

# -------------------------------- summary ----------------------------------
step "Done"
info "Removed what the setup installed; pre-existing packages were left in place."
info "Your files (setup script, README, prompt files, your projects) were NOT touched."
info "Open a new terminal so the cleaned PATH takes effect."
