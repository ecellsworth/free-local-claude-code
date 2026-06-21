# Validation of the setup process

Article: "Run Claude for FREE Locally (Using Ollama + Claude Code)"
https://dev.to/tj1609/run-claude-for-free-locally-using-ollama-claude-code-45lf
(article last edited 2026-05-29; validated 2026-06-20)

Sources cross-checked:
- Official Ollama + Claude Code integration — https://docs.ollama.com/integrations/claude-code
- Ollama macOS install docs — https://docs.ollama.com/macos
- Ollama releases (latest stable v0.21.2) — https://github.com/ollama/ollama/releases/latest
- claude-code-router README (config schema reference) — https://github.com/musistudio/claude-code-router
- Additional guides — DZone, PolySkill, Habr, decodethefuture (Ollama + Claude Code)

## Verdict

The article's **concept is sound and now works natively**: install Ollama,
install Claude Code, pull a local model, configure the environment, and launch.
Ollama added an **Anthropic-compatible API on localhost**, so Claude Code talks
to it directly — no third-party proxy required. The article had a few concrete
errors (mainly the env-var URL and a macOS install assumption). The delivered
`setup-claude-ollama.command` implements the article's exact flow with those
corrections, and runs fully **offline at zero cost**.

## Step-by-step assessment

| # | Article step | Status | Finding / correction |
|---|--------------|--------|----------------------|
| 1 | `curl ... ollama.com/install.sh \| sh` | OK on Linux; wrong on macOS | install.sh is Linux-only. macOS uses Homebrew or the `.dmg`. Script branches by OS. |
| 1 | `ollama -v` | OK | Valid. |
| 2 | "Install Claude CLI" | Redundant | Same product as step 3 (Claude Code). |
| 3 | `npm install -g @anthropic-ai/claude-code` | OK | Correct package. Also installable via `curl https://claude.ai/install.sh \| bash`. |
| 4 | `ollama pull qwen2.5-coder:7b` | OK | Valid local coding model; good default. |
| 5 | `export ANTHROPIC_BASE_URL=http://localhost:11434/v1` | **Wrong suffix** | Must be `http://localhost:11434` **without `/v1`**. The `/v1` path is OpenAI-style; Claude Code uses Ollama's Anthropic-compatible API at the root. Also set `ANTHROPIC_AUTH_TOKEN=ollama` and `ANTHROPIC_API_KEY=""` (per official docs). |
| 5 | `export PATH=...`, `source ~/.bashrc` | OK | Reasonable. |
| 6 | `ollama launch claude` | Now valid | Not available when the article was first written, but it **is now a real, official command** (Ollama v0.21.x). `ollama launch claude --model <local-model>` works. |
| 7 | `ollama pull glm-5:cloud` | Off-concept | `:cloud` models run on Ollama's servers (need internet + account; not free/offline). A commenter flagged this and the author agreed. The setup rejects `:cloud` models to stay zero-cost/offline. |

## What the corrected setup does

Faithful to the article's five steps, plus the requested robustness:

1. **Detects OS/arch** (macOS or Linux) and the Linux package manager.
2. **Preflight**: reports what's present, installs what's missing, then a hard
   **gate re-confirms** curl, Node, npm, Ollama, and Claude Code before setup
   continues — it aborts if any can't be confirmed.
3. **Installs with fallbacks** (`try_each`): Homebrew, Node (brew → node@22 →
   nvm; or apt/dnf/yum/pacman/zypper → nvm), Ollama (brew → cask → versioned
   `.dmg`; Linux install.sh with version/sudo variants), Claude Code (npm →
   sudo → `--unsafe-perm` → official installer).
4. **Latest stable versions**: queries GitHub `/releases/latest` (excludes
   pre-releases) for Ollama and nvm, rejects anything matching
   rc/beta/alpha/nightly, and falls back to a pinned known-good stable
   (Ollama `v0.21.2`, nvm `v0.40.1`). **Never beta/unstable.**
5. **Pulls the local model** with retries and a lighter local fallback model.
6. **Configures the environment** (article step 5, corrected) in the right
   shell rc: `ANTHROPIC_BASE_URL=http://localhost:11434`,
   `ANTHROPIC_AUTH_TOKEN=ollama`, `ANTHROPIC_API_KEY=""`, a large
   `OLLAMA_CONTEXT_LENGTH` (Claude Code needs ≥64k), and flags that disable
   Claude Code telemetry/auto-update/error-reporting so nothing leaves the
   machine.
7. **Launch** (article step 6): `ollama launch claude --model <model>` or
   `claude --model <model>`.
8. **Generates README.txt** and verifies the install.

## Offline / zero-cost confirmation

- Runtime endpoint is `http://localhost:11434` — your own machine, not a cloud
  service. No account, no API key, no usage cost.
- Local models only; `:cloud` models are rejected.
- Non-essential network traffic (telemetry/update/error reporting) is disabled.
- Only the one-time installation requires internet to download packages/model.

## Note on claude-code-router

An earlier draft used the `@musistudio/claude-code-router` proxy as a
workaround. Validation showed Ollama's native Anthropic-compatible API makes the
proxy unnecessary, and the proxy is not part of the article's concept, so it was
removed. (Its config schema was verified correct against the project README, and
it remains a valid option only if you later want to route to multiple
providers.)
