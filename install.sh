#!/usr/bin/env bash
# Install answer-in-korean through the Claude Code plugin marketplace mechanism.
#
#   ./install.sh                 register this checkout as a marketplace, install the plugin, select its output style
#   ./install.sh owner/repo      same, but register the GitHub repo instead of the local checkout (gets auto-updates)
#   ./install.sh --uninstall     uninstall the plugin, remove the marketplace, unset the output style if it is ours
#
# Honours CLAUDE_CONFIG_DIR (default ~/.claude). Needs the claude CLI and python3 (the Stop hook needs it too).
# Takes effect in the next Claude Code session.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
config=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
case $config in /*) ;; *) config=$PWD/$config ;; esac
settings=$config/settings.json
market=answer-in-korean
plugin=answer-in-korean@$market
style=answer-in-korean:korean-reply
legacy_link=$config/skills/answer-in-korean   # pre-marketplace install method

die() { echo "install.sh: $*" >&2; exit 1; }
cc() { env -u CLAUDECODE claude "$@"; }   # CLAUDECODE unset so this also works from inside a Claude session
command -v claude >/dev/null 2>&1 || die "claude CLI not found"
# Run python, don't just look for it: on macOS without Command Line Tools /usr/bin/python3 is a shim that fails.
python3 -c 'import json, sys' >/dev/null 2>&1 || die "python3 is required (used by the Stop hook and by this script)"
[[ -f $here/.claude-plugin/marketplace.json ]] || die "run this from the answer-in-korean checkout"

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

state=$(style_state)

if [[ ${1:-} == --uninstall ]]; then
  cc plugin uninstall "$plugin" 2>/dev/null && echo "uninstalled $plugin" || echo "$plugin was not installed"
  cc plugin marketplace remove "$market" 2>/dev/null && echo "removed marketplace $market" || echo "marketplace $market was not registered"
  if ours "$legacy_link"; then rm "$legacy_link"; echo "removed legacy symlink $legacy_link"
  elif [[ -L $legacy_link ]]; then echo "install.sh: $legacy_link points elsewhere; leaving it" >&2; fi
  if [[ $state == same ]]; then set_style -; echo "pick another style with /output-style in your next session"
  else echo "outputStyle is not ours; left as is"; fi
  exit 0
fi

source=${1:-$here}
[[ $source != -* ]] || die "unknown option: $source (only --uninstall is accepted)"

if ours "$legacy_link"; then rm "$legacy_link"; echo "removed legacy symlink $legacy_link (marketplace install replaces it)"
elif [[ -L $legacy_link ]]; then die "$legacy_link is a symlink to a different checkout; remove it first"
elif [[ -e $legacy_link ]]; then die "$legacy_link exists and is not a symlink; move it away first"; fi

cc plugin marketplace add "$source"
cc plugin install "$plugin"
if [[ $state == same ]]; then echo "outputStyle already $style"; else set_style "$style"; fi
echo "installed $plugin from $source; start a new session to use it"
if [[ -d $source ]]; then echo "a local marketplace loads in place: edits in $source apply at the next session start or /reload-plugins"
else echo "update later with: claude plugin marketplace update $market && claude plugin update $plugin"; fi
