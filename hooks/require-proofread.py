#!/usr/bin/env python3
"""Hook: a proofread Korean reply must keep every code span, URL and number it was given.

Claude Code (hooks/hooks.json, Stop): when the turn contains an Agent(ko-proofreader) call, the
final message must still contain each fenced block, backtick span, URL and multi-digit number that
the draft (the agent's prompt, read from the transcript) contained; otherwise the hook blocks once
so Claude restores them.

Codex (hooks/codex-hooks.json): Codex encrypts the spawn_agent message before hooks or transcripts
see it, so the draft is unavailable. The gate is therefore between the proofreader's returned text
(SubagentStop last_assistant_message, stashed under $PLUGIN_DATA) and the final reply (Stop): the
main model must print the returned text with every anchor intact. UserPromptSubmit clears the stash
so an interrupted turn cannot leak into the next one. Losses inside the proofreader are left to
its own prompt.

It deliberately does NOT force a skipped proofread: a Stop hook cannot hide the message already
on screen, so blocking would only make the user see the reply twice. The output style is what
makes the model call the agent before printing. Any failure inside this script lets the turn end.
Run with --self-test to check the decision logic.
"""
import json
import os
import re
import sys
import tempfile

AGENT = "ko-proofreader"

FENCE = re.compile(r"```.*?```", re.S)
# ponytail: anchors are backtick spans, URLs and multi-digit numbers; hedges/obligations
# (im-not-ai's modality gate) are left to the agent prompt because the agent legitimately
# collapses stacked hedges, which a count check would flag.
ANCHOR = re.compile(r"`[^`\n]+`|https?://\S+|\d+[.,]\d[\d.,]*|\d{2,}")


def entries(lines):
    for raw in reversed(lines):
        try:
            yield json.loads(raw)
        except ValueError:
            continue


def blocks(entry):
    content = (entry.get("message") or {}).get("content")
    return [b for b in content if isinstance(b, dict)] if isinstance(content, list) else content


def last_assistant_text(lines):
    """Claude Code transcript: text of the last assistant entry."""
    for entry in entries(lines):
        if entry.get("type") == "assistant":
            texts = [b.get("text", "") for b in blocks(entry) or [] if b.get("type") == "text"]
            if texts:
                return "\n".join(texts)
    return ""


def rollout_last_assistant_text(lines):
    """Codex rollout: text of the last assistant message item."""
    for entry in entries(lines):
        payload = entry.get("payload") or {}
        if entry.get("type") == "response_item" and payload.get("type") == "message" \
                and payload.get("role") == "assistant":
            content = payload.get("content") or []
            return "".join(c.get("text", "") for c in content if isinstance(c, dict))
    return ""


def proofread_draft_since_last_human_message(lines):
    """The prompt of the Agent(ko-proofreader) call after the last human user entry, else None.
    User entries that only carry tool_result blocks are not human messages."""
    for entry in entries(lines):
        content = blocks(entry)
        if entry.get("type") == "user":
            if isinstance(content, str) or any(b.get("type") == "text" for b in content or []):
                return None
            continue
        if entry.get("type") == "assistant":
            for b in content or []:
                inp = b.get("input") or {}
                if (b.get("type") == "tool_use" and b.get("name") == "Agent"
                        and AGENT in str(inp.get("subagent_type", ""))):
                    return str(inp.get("prompt", ""))
    return None


def missing_anchors(draft, final):
    return [a for a in dict.fromkeys(FENCE.findall(draft) + ANCHOR.findall(FENCE.sub("", draft)))
            if a not in final]


def block_reason(missing, source="your draft", fix="Re-emit the reply"):
    if not missing:
        return None
    shown = "; ".join(m[:80] for m in missing[:5])
    return (f"Your final reply lost {len(missing)} span(s) that {source} contained: {shown}. "
            "The proofreader must not change code, paths, URLs or numbers, and neither may you. "
            f"{fix} with these spans restored exactly as in {source}.")


# --- Codex: proofreader output stash ------------------------------------------------------

def stash_path(session_id):
    base = (os.environ.get("PLUGIN_DATA") or os.environ.get("CLAUDE_PLUGIN_DATA")
            or os.path.join(tempfile.gettempdir(), "answer-in-korean"))
    safe = re.sub(r"[^A-Za-z0-9_-]", "_", str(session_id or "none"))
    return os.path.join(base, f"proofread-{safe}.txt")


def stash_write(session_id, text):
    path = stash_path(session_id)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def stash_take(session_id):
    """Return and delete the stashed proofreader text, or None."""
    path = stash_path(session_id)
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return None
    try:
        os.remove(path)
    except OSError:
        pass
    return text


def decide(event, lines):
    """Return the block reason, or None to let the turn end."""
    hook = event.get("hook_event_name", "Stop")
    sid = event.get("session_id")
    if hook == "UserPromptSubmit":
        stash_take(sid)
        return None
    if hook == "SubagentStop":
        if AGENT in str(event.get("agent_type", "")) and event.get("last_assistant_message"):
            stash_write(sid, event["last_assistant_message"])
        return None
    if hook != "Stop" or event.get("stop_hook_active"):
        return None
    returned = stash_take(sid)
    if returned is not None:  # Codex
        final = event.get("last_assistant_message") or rollout_last_assistant_text(lines)
        return block_reason(missing_anchors(returned, final), source="the proofreader's text",
                            fix="Print the proofreader's text again")
    draft = proofread_draft_since_last_human_message(lines)  # Claude Code
    if draft is None:
        return None  # ponytail: no enforcement, see module docstring
    final = event.get("last_assistant_message") or last_assistant_text(lines)
    return block_reason(missing_anchors(draft, final))


def main():
    try:
        event = json.load(sys.stdin)
        if os.environ.get("AIK_HOOK_LOG"):  # troubleshooting: append every payload this hook sees
            with open(os.environ["AIK_HOOK_LOG"], "a", encoding="utf-8") as f:
                f.write(json.dumps(event, ensure_ascii=False) + "\n")
        path = event.get("transcript_path")
        lines = []
        if path and os.path.isfile(path):
            with open(path, encoding="utf-8") as f:
                lines = f.readlines()
        reason = decide(event, lines)
    except Exception:  # ponytail: a broken hook must never trap the user
        return
    if reason:
        json.dump({"decision": "block", "reason": reason}, sys.stdout)


def self_test():
    os.environ["PLUGIN_DATA"] = tempfile.mkdtemp(prefix="aik-selftest-")
    ko = "한국어 문장입니다. " * 40
    draft = ko + " 설정은 `~/.claude/settings.json` 217번째 줄, 버전 2.1.280, https://x.io/a 참고.\n```sh\nls -la\n```"
    reworded = draft.replace("217번째 줄", "이백십칠 번째 줄").replace("`~/.claude/settings.json`", "settings.json")

    # Claude Code transcript path
    human = json.dumps({"type": "user", "message": {"role": "user", "content": "질문"}})
    agent = json.dumps({"type": "assistant", "message": {"content": [
        {"type": "tool_use", "name": "Agent",
         "input": {"subagent_type": "answer-in-korean:ko-proofreader", "prompt": draft}}]}})
    result = json.dumps({"type": "user", "message": {"content": [{"type": "tool_result", "content": draft}]}})
    other = json.dumps({"type": "assistant", "message": {"content": [
        {"type": "tool_use", "name": "Agent", "input": {"subagent_type": "Explore", "prompt": "x"}}]}})
    final = json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": draft}]}})
    ev = {"last_assistant_message": draft, "stop_hook_active": False}

    assert decide(ev, [human, other]) is None, "skipped proofread is not enforced (would show the reply twice)"
    assert decide(ev, [human, agent, result]) is None, "identical anchors pass"
    assert decide({"stop_hook_active": False}, [human, agent, final]) is None, "falls back to transcript when field missing"
    assert decide({**ev, "stop_hook_active": True}, [human, agent, result]) is None, "second stop passes"
    assert decide(ev, ["not json", human, agent, result]) is None, "garbage lines are skipped"
    reason = decide({**ev, "last_assistant_message": reworded}, [human, agent, result])
    assert reason and "`~/.claude/settings.json`" in reason and "217" in reason, "lost anchors block"
    assert decide({**ev, "last_assistant_message": draft.replace("ls -la", "ls")}, [human, agent, result]), "changed code block blocks"
    assert decide({**ev, "last_assistant_message": reworded}, [agent, human]) is None, "agent call before the last human message does not count"
    assert missing_anchors("한 개 1개 2개", "하나 둘") == [], "single digits are not anchors"

    # Codex: proofreader output -> final reply
    sid = "sess-1"
    sub = {"hook_event_name": "SubagentStop", "session_id": sid, "agent_type": "ko-proofreader",
           "last_assistant_message": draft, "stop_hook_active": False}
    stop = {"hook_event_name": "Stop", "session_id": sid, "turn_id": "t1",
            "last_assistant_message": reworded, "stop_hook_active": False}
    assert decide(sub, []) is None and os.path.exists(stash_path(sid)), "SubagentStop stashes the proofreader's text and never blocks"
    decide({**sub, "session_id": "sess-2", "agent_type": "explorer"}, [])
    assert not os.path.exists(stash_path("sess-2")), "other agents are not stashed"
    reason = decide(stop, [])
    assert reason and "217" in reason and "proofreader's text" in reason, "Stop blocks a final that lost the proofreader's anchors"
    assert not os.path.exists(stash_path(sid)), "Stop consumes the stash"
    assert decide({**stop, "stop_hook_active": True}, []) is None, "second stop passes"
    decide(sub, [])
    assert decide({**stop, "last_assistant_message": draft}, []) is None, "Stop passes identical anchors"
    decide(sub, [])
    decide({"hook_event_name": "UserPromptSubmit", "session_id": sid}, [])
    assert decide(stop, []) is None, "a new prompt clears a stash left by an interrupted turn"
    decide(sub, [])
    rollout = json.dumps({"type": "response_item", "payload": {"type": "message", "role": "assistant",
                          "content": [{"type": "output_text", "text": reworded}]}})
    assert decide({**stop, "last_assistant_message": None}, [rollout]), "falls back to the rollout's last assistant message"
    assert decide(stop, [human, agent, result]), "without a stash, Stop falls back to the Claude transcript logic"
    print("ok")


if __name__ == "__main__":
    self_test() if "--self-test" in sys.argv else main()
