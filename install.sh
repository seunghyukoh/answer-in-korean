#!/usr/bin/env bash
# Install answer-in-korean into Claude Code and/or Codex CLI through their plugin marketplaces.
#
#   ./install.sh                       install into every CLI found on PATH (claude, codex) from this checkout
#   ./install.sh owner/repo            same, but register the GitHub repo instead of the local checkout (gets auto-updates)
#   ./install.sh --claude | --codex    restrict to one host (combinable with owner/repo)
#   ./install.sh --uninstall [--claude|--codex]
#
# Claude Code: registers the marketplace, installs the plugin, selects the output style in settings.json.
# Codex: registers the marketplace, installs the plugin (its hooks are reviewed at the next interactive start), and
# renders the proofreader agent role to $CODEX_HOME/agents/ko-proofreader.toml (plugins cannot ship agent roles).
# Honours CLAUDE_CONFIG_DIR (default ~/.claude) and CODEX_HOME (default ~/.codex). Needs python3.
# Takes effect in the next session of each CLI.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
market=answer-in-korean
plugin=answer-in-korean@$market
style=answer-in-korean:korean-reply

die() { echo "install.sh: $*" >&2; exit 1; }
abspath() { case $1 in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }

uninstall=; want_claude=; want_codex=; source=
for arg in "$@"; do
  case $arg in
    --uninstall) uninstall=1 ;;
    --claude) want_claude=1 ;;
    --codex) want_codex=1 ;;
    -*) die "unknown option: $arg" ;;
    *) [[ -z $source ]] || die "only one source may be given"; source=$arg ;;
  esac
done
if [[ -z $want_claude && -z $want_codex ]]; then
  command -v claude >/dev/null 2>&1 && want_claude=1
  command -v codex >/dev/null 2>&1 && want_codex=1
  [[ -n $want_claude || -n $want_codex ]] || die "neither claude nor codex CLI found"
else
  [[ -z $want_claude ]] || command -v claude >/dev/null 2>&1 || die "claude CLI not found"
  [[ -z $want_codex ]] || command -v codex >/dev/null 2>&1 || die "codex CLI not found"
fi
# Run python, don't just look for it: on macOS without Command Line Tools /usr/bin/python3 is a shim that fails.
python3 -c 'import json, sys' >/dev/null 2>&1 || die "python3 is required (used by the hooks and by this script)"
[[ -f $here/.claude-plugin/marketplace.json && -f $here/.agents/plugins/marketplace.json ]] || die "run this from the answer-in-korean checkout"
source=${source:-$here}

# ---------------------------------------------------------------- Claude Code
config=$(abspath "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")
settings=$config/settings.json
legacy_link=$config/skills/answer-in-korean   # pre-marketplace install method
cc() { env -u CLAUDECODE claude "$@"; }   # CLAUDECODE unset so this also works from inside a Claude session

# style_state : prints "same", "other" or "absent" for outputStyle vs $style; dies if settings.json is unusable.
# Called before anything is changed so a broken settings.json never leaves a half-install.
style_state() {
  [[ -f $settings ]] || { echo absent; return; }
  python3 - "$settings" "$style" <<'PY'
import json, sys
path, want = sys.argv[1], sys.argv[2]
raw = open(path, encoding="utf-8").read()
try:
    data = json.loads(raw.strip() or "{}")
except json.JSONDecodeError as e:
    sys.exit(f"install.sh: {path} is not valid JSON ({e}); fix it and re-run (nothing was changed)")
if not isinstance(data, dict):
    sys.exit(f"install.sh: {path} must contain a JSON object (nothing was changed)")
cur = data.get("outputStyle")
print("same" if cur == want else "absent" if cur is None else "other")
PY
}

# set_style VALUE|-  : writes outputStyle (or removes it with "-"). Other keys are kept but the file is
# re-serialised (2-space indent). Backs up first, writes atomically, follows a symlinked settings.json.
set_style() {
  if [[ -f $settings ]]; then
    cp -p "$settings" "$settings.bak.$(date +%Y%m%d-%H%M%S).$$"
  else
    mkdir -p "$(dirname "$settings")"; printf '{}\n' > "$settings"
  fi
  python3 - "$settings" "$1" <<'PY'
import json, os, sys, tempfile
path, value = sys.argv[1], sys.argv[2]
real = os.path.realpath(path)
with open(real, encoding="utf-8") as f:
    data = json.loads(f.read().strip() or "{}")
previous = data.get("outputStyle")
if value == "-":
    data.pop("outputStyle", None)
else:
    data["outputStyle"] = value
text = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(real), prefix=".settings.json.")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.write(text)
try:
    os.chmod(tmp, os.stat(real).st_mode & 0o7777)
except OSError:
    pass
os.replace(tmp, real)
print(f"outputStyle: {previous!r} -> {data.get('outputStyle')!r}")
PY
}

# ours PATH : true if PATH is a symlink that resolves to this checkout.
ours() { [[ -L $1 ]] && [[ $(cd -P -- "$1" 2>/dev/null && pwd -P) == "$(cd -P -- "$here" && pwd -P)" ]]; }

claude_uninstall() {
  local state; state=$(style_state)
  cc plugin uninstall "$plugin" 2>/dev/null && echo "uninstalled $plugin" || echo "$plugin was not installed"
  cc plugin marketplace remove "$market" 2>/dev/null && echo "removed marketplace $market" || echo "marketplace $market was not registered"
  if ours "$legacy_link"; then rm "$legacy_link"; echo "removed legacy symlink $legacy_link"
  elif [[ -L $legacy_link ]]; then echo "install.sh: $legacy_link points elsewhere; leaving it" >&2; fi
  if [[ $state == same ]]; then set_style -; echo "pick another style with /output-style in your next session"
  else echo "outputStyle is not ours; left as is"; fi
}

claude_install() {
  local state; state=$(style_state)
  if ours "$legacy_link"; then rm "$legacy_link"; echo "removed legacy symlink $legacy_link (marketplace install replaces it)"
  elif [[ -L $legacy_link ]]; then die "$legacy_link is a symlink to a different checkout; remove it first"
  elif [[ -e $legacy_link ]]; then die "$legacy_link exists and is not a symlink; move it away first"; fi
  cc plugin marketplace add "$source"
  cc plugin install "$plugin"
  if [[ $state == same ]]; then echo "outputStyle already $style"; else set_style "$style"; fi
  echo "claude: installed $plugin from $source; start a new session to use it"
  if [[ -d $source ]]; then echo "claude: a local marketplace loads in place: edits in $source apply at the next session start or /reload-plugins"
  else echo "claude: update later with: claude plugin marketplace update $market && claude plugin update $plugin"; fi
}

# ---------------------------------------------------------------- Codex
codex_home=$(abspath "${CODEX_HOME:-$HOME/.codex}")
agent_toml=$codex_home/agents/ko-proofreader.toml
marker='# generated by answer-in-korean install.sh'
cx() { env -u CLAUDECODE codex "$@"; }

# render_agent : $here/agents/ko-proofreader.md -> $agent_toml. Codex plugins cannot ship agent roles, so the
# one prompt file is rendered into a role TOML at install time. Refuses to overwrite a file that is not ours.
render_agent() {
  mkdir -p "$(dirname "$agent_toml")"
  python3 - "$here/agents/ko-proofreader.md" "$agent_toml" "$marker" <<'PY'
import json, os, sys, tempfile
src, dst, marker = sys.argv[1:4]
text = open(src, encoding="utf-8").read()
head, _, body = text.partition("\n---\n")          # frontmatter ends at the second ---
meta = dict(line.split(":", 1) for line in head.splitlines() if ":" in line and not line.startswith("---"))
meta = {k.strip(): v.strip() for k, v in meta.items()}
body = body.strip("\n") + "\n"
if "'''" in body:
    sys.exit("install.sh: agents/ko-proofreader.md contains ''' which cannot be embedded in a TOML literal string")
if os.path.exists(dst):
    with open(dst, encoding="utf-8") as f:
        if not f.readline().startswith(marker):
            sys.exit(f"install.sh: {dst} exists and was not generated by this script; move it away first")
toml = (f"{marker}; edit agents/ko-proofreader.md and re-run install.sh\n"
        f'name = "ko-proofreader"\n'
        f"description = {json.dumps(meta.get('description', ''), ensure_ascii=False)}\n"
        f"model_reasoning_effort = {json.dumps(meta.get('effort', 'low'))}\n"
        f"developer_instructions = '''\n{body}'''\n")
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(dst), prefix=".ko-proofreader.toml.")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.write(toml)
os.replace(tmp, dst)
print(f"codex: wrote {dst}")
PY
}

codex_uninstall() {
  cx plugin remove "$plugin" >/dev/null 2>&1 && echo "codex: removed $plugin" || echo "codex: $plugin was not installed"
  cx plugin marketplace remove "$market" >/dev/null 2>&1 && echo "codex: removed marketplace $market" || echo "codex: marketplace $market was not registered"
  if [[ -f $agent_toml ]] && head -1 "$agent_toml" | grep -qF "$marker"; then rm "$agent_toml"; echo "codex: removed $agent_toml"
  elif [[ -e $agent_toml ]]; then echo "install.sh: $agent_toml is not ours; leaving it" >&2; fi
}

codex_install() {
  cx plugin marketplace add "$source" >/dev/null || cx plugin marketplace list 2>/dev/null | grep -q "^$market " \
    || die "codex plugin marketplace add $source failed"
  cx plugin add "$plugin" >/dev/null || die "codex plugin add $plugin failed"
  render_agent
  if grep -qiE 'respond in English|answer in English' "$codex_home/AGENTS.md" 2>/dev/null; then
    echo "install.sh: $codex_home/AGENTS.md asks for English replies; the plugin's rule takes precedence, but consider removing that line" >&2
  fi
  echo "codex: installed $plugin from $source; Codex asks you to approve the plugin's hooks when you next start it"
  echo "codex: the plugin is copied at install: after editing $source re-run install.sh (or codex plugin add $plugin) to refresh the copy"
}

if [[ -n $uninstall ]]; then
  [[ -z $want_claude ]] || claude_uninstall
  [[ -z $want_codex ]] || codex_uninstall
  exit 0
fi
[[ -z $want_claude ]] || claude_install
[[ -z $want_codex ]] || codex_install
