#!/usr/bin/env python3
"""Stop hook: a proofread Korean reply must keep every code span, URL and number from the draft.

Reads the Stop event on stdin. When the turn contains an Agent(ko-proofreader) call, the final
message must still contain each fenced block, backtick span, URL and multi-digit number that the
draft (the agent's prompt) contained; otherwise the hook blocks once so Claude restores them.

It deliberately does NOT force a skipped proofread: a Stop hook cannot hide the message already
on screen, so blocking would only make the user see the reply twice. The output style is what
makes Claude call the agent before printing. Any failure inside this script lets Claude stop.
Run with --self-test to check the decision logic.
"""
import json
import re
import sys

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
    for entry in entries(lines):
        if entry.get("type") == "assistant":
            texts = [b.get("text", "") for b in blocks(entry) or [] if b.get("type") == "text"]
            if texts:
                return "\n".join(texts)
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


def decide(event, lines):
    """Return the block reason, or None to let Claude stop."""
    if event.get("stop_hook_active"):
        return None
    draft = proofread_draft_since_last_human_message(lines)
    if draft is None:
        return None  # ponytail: no enforcement, see module docstring
    final = event.get("last_assistant_message") or last_assistant_text(lines)
    missing = missing_anchors(draft, final)
    if missing:
        shown = "; ".join(m[:80] for m in missing[:5])
        return (f"Your final reply lost {len(missing)} span(s) that your draft contained: {shown}. "
                "The proofreader must not change code, paths, URLs or numbers. Re-emit the reply "
                "with these spans restored exactly as in your draft.")
    return None


def main():
    try:
        event = json.load(sys.stdin)
        with open(event["transcript_path"], encoding="utf-8") as f:
            lines = f.readlines()
        reason = decide(event, lines)
    except Exception:  # ponytail: a broken hook must never trap the user
        return
    if reason:
        json.dump({"decision": "block", "reason": reason}, sys.stdout)


def self_test():
    ko = "한국어 문장입니다. " * 40
    draft = ko + " 설정은 `~/.claude/settings.json` 217번째 줄, 버전 2.1.280, https://x.io/a 참고.\n```sh\nls -la\n```"
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
    reworded = draft.replace("217번째 줄", "이백십칠 번째 줄").replace("`~/.claude/settings.json`", "settings.json")
    reason = decide({**ev, "last_assistant_message": reworded}, [human, agent, result])
    assert reason and "`~/.claude/settings.json`" in reason and "217" in reason, "lost anchors block"
    assert decide({**ev, "last_assistant_message": draft.replace("ls -la", "ls")}, [human, agent, result]), "changed code block blocks"
    assert decide({**ev, "last_assistant_message": reworded}, [agent, human]) is None, "agent call before the last human message does not count"
    assert missing_anchors("한 개 1개 2개", "하나 둘") == [], "single digits are not anchors"
    print("ok")


if __name__ == "__main__":
    self_test() if "--self-test" in sys.argv else main()
