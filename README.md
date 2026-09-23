# answer-in-korean

Claude Code and Codex CLI plugin. The model works in English (reasoning, tool calls, code, commits)
and replies in Korean, and the Korean reply is proofread by a subagent before you see it.

## Why

English is where the model is fastest and most accurate; Korean is what you want to read.
Raw LLM Korean fails in two ways: translationese and AI formulas (`결론적으로`, `~에 대해`, a
comma after `~하지만`), and telegraphic Korean with particles and endings dropped. The
proofreader fixes both, and you only ever see the corrected text.

## How it works

```
main model (English work)
  → sends the Korean reply as the task of the ko-proofreader subagent
  → the agent fixes tells and returns clean text
  → main model prints the returned text verbatim as its final message
```

| Piece | Claude Code | Codex |
| --- | --- | --- |
| Language rule and pipeline | `output-styles/korean-reply.md`, selected as the output style | the same file, injected as context at `SessionStart` by `hooks/codex-hooks.json` (again on resume and after compaction) |
| The reviewer | `agents/ko-proofreader.md`, called with `Agent` and `subagent_type: answer-in-korean:ko-proofreader` | the same prompt, rendered by `install.sh` into `~/.codex/agents/ko-proofreader.toml` and called with `spawn_agent` and `agent_type: ko-proofreader` (Codex plugins cannot ship agent roles) |
| Anchor gate | `hooks/hooks.json`: `Stop` compares the draft (the agent's prompt, read from the transcript) with the printed reply | `hooks/codex-hooks.json`: `SubagentStop` stashes the proofreader's returned text under `PLUGIN_DATA`, `Stop` compares it with the printed reply, `UserPromptSubmit` clears a stash left by an interrupted turn |
| Manifests | `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` | `.codex-plugin/plugin.json`, `.agents/plugins/marketplace.json` |

Both gates run `hooks/require-proofread.py`: if the printed reply lost a backtick span, URL,
fenced block or multi-digit number that the reference text had, the hook blocks once and the model
restores them. It judges, it never edits text.

The reference differs per host because of what each host lets a hook see. Claude Code's transcript
holds the agent prompt, so its gate checks draft → printed reply, which also catches a proofreader
that dropped a span. Codex encrypts the `spawn_agent` message before hooks or transcripts see it
(the parent rollout stores a `gAAAA…` blob, the child rollout an empty payload, and `PreToolUse`
receives the same blob), so the Codex gate checks proofreader output → printed reply. A span
dropped inside the Codex proofreader is caught only by its own prompt.

No hook can rewrite the final message after it is generated (`Stop` only sees it read-only), so
the review has to happen inside the turn. That is why it is a subagent and not a post-processor.
For the same reason the hook does not force a skipped review: a block can only make the model
send the reply again, and the user would see it twice. One- or two-sentence replies, code-only
replies, and English replies (`en`) skip the agent.

## Install

The repo is its own plugin marketplace for both hosts (`.claude-plugin/marketplace.json` and
`.agents/plugins/marketplace.json`, both pointing at `./`).

From a local checkout:

```bash
git clone https://github.com/seunghyukoh/answer-in-korean ~/orca/projects/answer-in-korean   # or wherever you keep it
cd ~/orca/projects/answer-in-korean
./install.sh                  # every CLI found on PATH
./install.sh --codex          # or --claude, to pick one
```

`./install.sh seunghyukoh/answer-in-korean` registers the GitHub repo as the marketplace instead of
the checkout. The manual equivalents:

```
# Claude Code, inside a session
/plugin marketplace add seunghyukoh/answer-in-korean
/plugin install answer-in-korean@answer-in-korean
/output-style answer-in-korean:korean-reply
```

```bash
# Codex
codex plugin marketplace add seunghyukoh/answer-in-korean
codex plugin add answer-in-korean@answer-in-korean
./install.sh --codex          # still needed once: it renders ~/.codex/agents/ko-proofreader.toml
```

What `install.sh` does:

- Claude Code: `claude plugin marketplace add`, `claude plugin install`, sets `outputStyle` in
  `~/.claude/settings.json` after backing it up, and removes the older
  `~/.claude/skills/answer-in-korean` symlink if it finds one. Honours `CLAUDE_CONFIG_DIR`.
- Codex: `codex plugin marketplace add`, `codex plugin add`, renders `agents/ko-proofreader.md`
  into `$CODEX_HOME/agents/ko-proofreader.toml` (first line is a marker so uninstall only removes
  its own file), and warns if `~/.codex/AGENTS.md` asks for English replies. Honours `CODEX_HOME`.
  Codex reviews new hooks by hash: the next interactive `codex` start asks you to approve the
  plugin's four hooks, and until then they do not run (`codex exec --dangerously-bypass-hook-trust`
  runs them without the review).
- `./install.sh --uninstall [--claude|--codex]` reverses all of it. Everything takes effect in the
  next session.

Updates:

- Claude Code, local marketplace: loads in place, edits apply at the next session start or
  `/reload-plugins`. GitHub marketplace: bump `version` in `.claude-plugin/plugin.json`, then
  `claude plugin marketplace update answer-in-korean && claude plugin update answer-in-korean@answer-in-korean`,
  or turn on auto-update (`/plugin` → Marketplaces → Auto-update).
- Codex copies the plugin into `~/.codex/plugins/cache/answer-in-korean/answer-in-korean/<version>/`
  at install, from a local or a GitHub marketplace alike. After editing, re-run
  `./install.sh --codex` (or `codex plugin add answer-in-korean@answer-in-korean`); it refreshes the
  copy even at the same version and re-renders the agent TOML. For a GitHub marketplace run
  `codex plugin marketplace upgrade answer-in-korean` first. Keep the `version` fields of the two
  manifests equal.

The "subagents return English" rule in `~/.claude/CLAUDE.md` does not reach the Claude proofreader:
the agent sets `omitClaudeMd: true`. Codex has no such switch, so the prompt tells the agent that
outside language rules do not apply to it. A `~/.codex/AGENTS.md` line demanding English replies
still contradicts the injected rule on every turn; the style's Precedence section wins, but drop the
line.

## Tuning

- Reviewer model and effort, Claude Code: `model:` and `effort:` in `agents/ko-proofreader.md`.
  Default is `sonnet` at `effort: low`, which on a 2,200-character draft took about 30 s and removed
  11 of 13 connective-ending commas with no other damage. `effort: medium` caught all 13 in about
  60 s. `haiku` was not faster through this gateway and got confused by the surrounding
  instructions; `fable` is the quality ceiling at the highest cost.
- Reviewer model and effort, Codex: the agent inherits the parent's model, and `effort:` from the
  same file becomes `model_reasoning_effort` in the rendered TOML (re-run `install.sh --codex` after
  changing it). To pin a different model add `model = "..."` to the TOML; the file is regenerated at
  the next install, so re-apply it then.
- Anchor gate off: delete `hooks/hooks.json` (Claude Code) or the `SubagentStop` and `Stop` entries
  in `hooks/codex-hooks.json` (Codex).
- Whole plugin off: `claude plugin disable answer-in-korean@answer-in-korean`; in Codex set
  `enabled = false` under `[plugins."answer-in-korean@answer-in-korean"]` in `~/.codex/config.toml`.
- Hook troubleshooting: with `AIK_HOOK_LOG=/some/file` in the environment the hook appends every
  payload it receives to that file.

Cost: one extra model call per long reply, roughly 20 to 40 seconds on Claude Code with sonnet, and
about 10 to 15 seconds on Codex in the runs so far.

## Check

```bash
claude plugin validate .
python3 hooks/require-proofread.py --self-test
codex plugin list | grep answer-in-korean      # after install
```

## Credits

- [epoko77-ai/im-not-ai](https://github.com/epoko77-ai/im-not-ai) (MIT): AI-tell taxonomy and the
  post-editing directives (fidelity, locality, removal-only, change budget, modality
  invariance, deterministic anchor gates, "delete, never invent").
- [snflkd/fluent-korean](https://github.com/snflkd/fluent-korean) (MIT): the telegraphic-Korean rules.

Nothing was copied from either repo; the rules were re-derived and rewritten for chat replies.
