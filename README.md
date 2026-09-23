# answer-in-korean

Claude Code plugin. Claude works in English (reasoning, tool calls, code, commits) and
replies in Korean, and the Korean reply is proofread by a subagent before you see it.

## Why

English is where the model is fastest and most accurate; Korean is what you want to read.
Raw LLM Korean fails in two ways: translationese and AI formulas (`결론적으로`, `~에 대해`, a
comma after `~하지만`), and telegraphic Korean with particles and endings dropped. The
proofreader fixes both, and you only ever see the corrected text.

## How it works

```
main model (English work)
  → composes the Korean reply as the prompt of Agent(answer-in-korean:ko-proofreader)
  → the agent (sonnet) fixes tells and returns clean text
  → main model prints the returned text verbatim as its final message
```

| File | Role |
| --- | --- |
| `output-styles/korean-reply.md` | Language rule and the pipeline instruction. Select it as your output style. |
| `agents/ko-proofreader.md` | The reviewer. Rules distilled from im-not-ai and fluent-korean. |
| `hooks/hooks.json`, `hooks/require-proofread.py` | `Stop` hook, one gate: if the proofread reply lost a backtick span, URL, fenced block or multi-digit number that the draft had, it blocks once and Claude restores them. It judges, it never edits text. |

No hook can rewrite Claude's final message after it is generated (`Stop` only sees it
read-only), so the review has to happen inside the turn. That is why it is a subagent and
not a post-processor. For the same reason the hook does not force a skipped review: a block
can only make Claude send the reply again, and the user would see it twice. One- or
two-sentence replies, code-only replies, and English replies (`en`) skip the agent.

## Install

The repo is its own plugin marketplace (`.claude-plugin/marketplace.json`, source `./`).

From a local checkout:

```bash
git clone <this repo> ~/orca/projects/answer-in-korean   # or wherever you keep it
cd ~/orca/projects/answer-in-korean
./install.sh
```

From GitHub, once the repo is pushed (inside Claude Code):

```
/plugin marketplace add seunghyukoh/answer-in-korean
/plugin install answer-in-korean@answer-in-korean
/output-style answer-in-korean:korean-reply
```

or `./install.sh seunghyukoh/answer-in-korean` from a checkout, which does the same three steps.

`install.sh` registers the marketplace (`claude plugin marketplace add`), installs the plugin
(`claude plugin install answer-in-korean@answer-in-korean`), sets `outputStyle` to
`answer-in-korean:korean-reply` in `~/.claude/settings.json` after backing it up, and removes the
older `~/.claude/skills/answer-in-korean` symlink if it finds one. It honours `CLAUDE_CONFIG_DIR`.
`./install.sh --uninstall` reverses all of it. Everything takes effect in the next session.

Updates: a marketplace added from a local directory loads the plugin in place, so edits to the
checkout take effect at the next session start or `/reload-plugins`, no version bump needed. A
GitHub-sourced marketplace copies the plugin into `~/.claude/plugins/cache/`; there you bump
`version` in `.claude-plugin/plugin.json` and run

```bash
claude plugin marketplace update answer-in-korean && claude plugin update answer-in-korean@answer-in-korean
```

or turn on auto-update (`/plugin` → Marketplaces → Auto-update).

The "subagents return English" rule in `~/.claude/CLAUDE.md` does not reach the proofreader:
the agent sets `omitClaudeMd: true`.

## Tuning

- Reviewer model and effort: `model:` and `effort:` in `agents/ko-proofreader.md`. Default is
  `sonnet` at `effort: low`, which on a 2,200-character draft took about 30 s and removed 11 of
  13 connective-ending commas with no other damage. `effort: medium` caught all 13 in about
  60 s. `haiku` was not faster through this gateway and got confused by the surrounding
  instructions; `fable` is the quality ceiling at the highest cost.
- Anchor gate off: delete `hooks/hooks.json`.
- Whole plugin off: `claude plugin disable answer-in-korean@answer-in-korean`.

Cost: one extra sonnet call per long reply, roughly 20 to 40 seconds depending on length.

## Check

```bash
claude plugin validate .
python3 hooks/require-proofread.py --self-test
```

## Credits

- [epoko77-ai/im-not-ai](https://github.com/epoko77-ai/im-not-ai): AI-tell taxonomy and the
  post-editing directives (fidelity, locality, removal-only, change budget, modality
  invariance, deterministic anchor gates, "delete, never invent").
- [snflkd/fluent-korean](https://github.com/snflkd/fluent-korean): the telegraphic-Korean rules.
