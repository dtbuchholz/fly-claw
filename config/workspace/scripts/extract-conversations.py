#!/usr/bin/env python3
"""Extract compact, high-signal digests from OpenClaw conversation JSONL files.

Reads raw session transcripts and writes concise markdown digests optimized for
QMD retrieval — filters out tool calls, system noise, and boilerplate to keep
only user goals, assistant outcomes, decisions, and open threads.

Output structure (one digest per session-day):
  <OUTPUT_DIR>/main/<session-id>__YYYY-MM-DD.md
  <OUTPUT_DIR>/claude/<session-id>__YYYY-MM-DD.md
  <OUTPUT_DIR>/codex/<session-id>__YYYY-MM-DD.md

Adapted from dtbuchholz/claude-config extract-conversations.py for OpenClaw's
JSONL format (type="message", message.role, message.content[]).
"""

import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

# --- Config ---
OPENCLAW_DIR = Path(
    sys.argv[1] if len(sys.argv) > 1 else "/data/.openclaw"
)
AGENTS_DIR = OPENCLAW_DIR / "agents"
OUTPUT_DIR = OPENCLAW_DIR / "conversations"

MAX_USER_ITEMS = 6
MAX_ASSISTANT_ITEMS = 6
MAX_SECTION_ITEMS = 8
MAX_TEXT_CHARS = 420

# Sessions smaller than this are likely cron runs — skip them
MIN_SESSION_BYTES = 10_000

# --- Patterns ---
NOISE_PATTERNS = [
    re.compile(r"^Conversation info \(untrusted", re.IGNORECASE),
    re.compile(r"^Sender \(untrusted metadata\)", re.IGNORECASE),
    re.compile(r"^```json\s*\{", re.IGNORECASE),
    re.compile(r"^Pre-compaction memory flush", re.IGNORECASE),
    re.compile(r"^NO_REPLY\s*$", re.IGNORECASE),
    re.compile(r"^HEARTBEAT_OK\s*$", re.IGNORECASE),
    re.compile(r"^ANNOUNCE_SKIP\s*$", re.IGNORECASE),
    re.compile(r"^\[System Message\]", re.IGNORECASE),
    re.compile(r"^\[Audio\]\s*$", re.IGNORECASE),
    re.compile(r"^System:", re.IGNORECASE),
    re.compile(r"^<environment_context>", re.IGNORECASE),
    re.compile(r"^Project Guidelines", re.IGNORECASE),
]

SIGNAL_HINTS = [
    "fixed", "added", "updated", "implemented", "created", "removed",
    "verified", "committed", "merged", "completed", "passed", "blocked",
    "failed", "error", "issue", "plan", "decision", "constraint",
    "tradeoff", "deployed", "configured", "enabled", "disabled",
]

QUESTION_STARTERS = (
    "what ", "how ", "why ", "when ", "where ", "who ", "which ",
    "can ", "could ", "should ", "would ", "did ", "is ", "are ",
    "do ", "does ",
)

CONSTRAINT_HINTS = (
    "must", "should", "only", "don't", "do not", "cannot", "can't",
    "avoid", "ignore", "use ", "start with",
)

DECISION_HINTS = (
    "decide", "decision", "recommend", "best approach", "tradeoff",
    "we should", "let's", "instead", "option",
)

ACTION_HINTS = (
    "added", "updated", "implemented", "created", "removed", "renamed",
    "fixed", "tested", "verified", "committed", "pushed", "configured",
    "installed", "deployed", "enabled", "disabled", "opened", "merged",
)

ISSUE_HINTS = (
    "error", "failed", "leak", "blocked", "problem", "issue",
    "mismatch", "not found", "cannot", "can't", "broken", "bug",
)

OPEN_HINTS = (
    "next step", "next steps", "follow-up", "todo", "to do",
    "pending", "later", "can you", "should we", "want me to",
)

ANSI_RE = re.compile(r"\x1B\[[0-?]*[ -/]*[@-~]")

# OpenClaw wraps user messages in metadata headers — strip them to get the actual content
OPENCLAW_META_RE = re.compile(
    r"^(?:Conversation info \(untrusted.*?\n```\n\n?"
    r"|Sender \(untrusted.*?\n```\n\n?"
    r"|\[(?:Audio|Telegram).*?\n(?:User text:\n)?(?:\[.*?\]\s*<media:\w+>\s*\n?)?(?:Transcript:\s*\n?)?)",
    re.DOTALL | re.MULTILINE,
)
PLAUSIBLE_PATH_RE = re.compile(
    r"(~?/[\w\-.~/]+|[\w\-.]+/[\w\-.~/]+|[\w\-.]+\.(md|py|ts|tsx|js|json|toml|sh|yaml|yml))"
)
PATH_TOKEN_RE = re.compile(r"`([^`]+)`")

TOOL_OUTPUT_NOISE = (
    "Chunk ID:", "Wall time:", "Process exited with code",
    "Original token count:", "Output:", "[compacted:",
)


def strip_openclaw_meta(text: str) -> str:
    """Remove OpenClaw metadata headers from user messages to get actual content."""
    # Strip Conversation info blocks
    t = re.sub(
        r'Conversation info \(untrusted metadata\):\s*```json\s*\{[^}]*\}\s*```\s*',
        '', text, flags=re.DOTALL
    ).strip()
    # Strip Sender blocks
    t = re.sub(
        r'Sender \(untrusted metadata\):\s*```json\s*\{[^}]*\}\s*```\s*',
        '', t, flags=re.DOTALL
    ).strip()
    # Strip Audio/Telegram transcript headers
    t = re.sub(
        r'\[Audio\]\s*User text:\s*\[Telegram[^\]]*\]\s*(?:<media:\w+>\s*)?Transcript:\s*',
        '', t, flags=re.DOTALL
    ).strip()
    # Strip standalone [Audio] tags
    t = re.sub(r'^\[Audio\]\s*', '', t).strip()
    # Strip System message blocks
    t = re.sub(r'^\[.*?\] \[System Message\].*$', '', t, flags=re.MULTILINE).strip()
    t = re.sub(r'^System: \[.*?\].*$', '', t, flags=re.MULTILINE).strip()
    return t


def is_noise(text: str) -> bool:
    t = text.strip()
    if not t:
        return True
    return any(p.search(t) for p in NOISE_PATTERNS)


def normalize(text: str) -> str:
    t = ANSI_RE.sub("", text)
    t = " ".join(t.strip().split())
    if len(t) > MAX_TEXT_CHARS:
        t = t[:MAX_TEXT_CHARS].rstrip() + "..."
    return t


def sanitize_tool_output(text: str) -> str:
    lines = []
    for raw in ANSI_RE.sub("", text).splitlines():
        line = raw.strip()
        if not line or any(line.startswith(p) for p in TOOL_OUTPUT_NOISE):
            continue
        lines.append(line)
    if not lines:
        return ""
    condensed = " ".join(lines)
    return condensed[:220].rstrip() + "..." if len(condensed) > 220 else condensed


def should_keep_tool_result(text: str) -> bool:
    if not text or len(text) < 16:
        return False
    low = text.lower()
    keep_hints = ACTION_HINTS + ISSUE_HINTS + (
        "passed", "coverage", "commit", "push", "qmd", "hook",
    )
    return any(h in low for h in keep_hints) or PLAUSIBLE_PATH_RE.search(text) is not None


def parse_timestamp(ts: str) -> Optional[datetime]:
    if not ts:
        return None
    value = ts.strip()
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(value)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def date_key(ts: str) -> str:
    dt = parse_timestamp(ts)
    return dt.strftime("%Y-%m-%d") if dt else "undated"


def signal_score(text: str) -> int:
    t = text.lower()
    score = 0
    if any(h in t for h in SIGNAL_HINTS):
        score += 2
    if "/" in text or any(ext in text for ext in (".md", ".ts", ".py", ".json", ".sh")):
        score += 1
    if "```" in text or any(cmd in t for cmd in ("git ", "npm ", "qmd ", "make ")):
        score += 1
    if 40 <= len(text) <= MAX_TEXT_CHARS:
        score += 1
    return score


def dedupe(items: list[str]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for item in items:
        if item not in seen:
            seen.add(item)
            out.append(item)
    return out


def top_snippets(items: list[str], max_items: int) -> list[str]:
    cleaned = dedupe([normalize(x) for x in items if not is_noise(x)])
    ranked = sorted(cleaned, key=signal_score, reverse=True)
    strong = [x for x in ranked if signal_score(x) >= 1]
    return (strong or cleaned)[:max_items]


def contains_any(text: str, hints: tuple[str, ...]) -> bool:
    t = text.lower()
    return any(h in t for h in hints)


def extract_artifacts(items: list[str]) -> list[str]:
    artifacts: list[str] = []
    for item in items:
        for m in PATH_TOKEN_RE.findall(item):
            if "/" in m or "." in m:
                artifacts.append(m)
        for m in PLAUSIBLE_PATH_RE.findall(item):
            token = m[0] if isinstance(m, tuple) else m
            if token:
                artifacts.append(token)
    return dedupe([normalize(x).strip(".,:;") for x in artifacts if x])[:MAX_SECTION_ITEMS]


def categorize_user(items: list[str]):
    goals, constraints, questions = [], [], []
    for item in items:
        low = item.lower().strip()
        if "?" in item or low.startswith(QUESTION_STARTERS):
            questions.append(item)
        if contains_any(item, CONSTRAINT_HINTS):
            constraints.append(item)
        if not is_noise(item):
            goals.append(item)
    return (
        top_snippets(goals, MAX_SECTION_ITEMS),
        top_snippets(constraints, MAX_SECTION_ITEMS),
        top_snippets(questions, MAX_SECTION_ITEMS),
    )


def categorize_assistant(items: list[str]):
    decisions, actions, issues, open_threads = [], [], [], []
    for item in items:
        if contains_any(item, DECISION_HINTS):
            decisions.append(item)
        if contains_any(item, ACTION_HINTS):
            actions.append(item)
        if contains_any(item, ISSUE_HINTS):
            issues.append(item)
        if contains_any(item, OPEN_HINTS):
            open_threads.append(item)
    return (
        top_snippets(decisions, MAX_SECTION_ITEMS),
        top_snippets(actions, MAX_SECTION_ITEMS),
        top_snippets(issues, MAX_SECTION_ITEMS),
        top_snippets(open_threads, MAX_SECTION_ITEMS),
    )


def build_digest(label: str, user_items: list[str], assistant_items: list[str],
                 first_ts: str, last_ts: str) -> str:
    user_items = dedupe([normalize(x) for x in user_items if not is_noise(x)])
    assistant_items = dedupe([normalize(x) for x in assistant_items if not is_noise(x)])

    if not user_items and not assistant_items:
        return ""

    goals, constraints, questions = categorize_user(user_items)
    decisions, actions, issues, open_threads = categorize_assistant(assistant_items)
    artifacts = extract_artifacts(user_items + assistant_items)

    lines = [f"# {label}", ""]
    lines.append("## Session Metadata")
    lines.append(f"- first_event: {first_ts or '(unknown)'}")
    lines.append(f"- last_event: {last_ts or '(unknown)'}")
    lines.append(f"- user_messages: {len(user_items)}")
    lines.append(f"- assistant_messages: {len(assistant_items)}")
    lines.append("")

    def section(title: str, items: list[str]):
        lines.append(f"### {title}")
        if items:
            lines.extend(f"- {x}" for x in items)
        else:
            lines.append("- (none)")

    lines.append("## User Intent")
    section("Goals", goals)
    section("Constraints", constraints)
    section("Questions", questions)
    lines.append("")

    lines.append("## Assistant Work")
    section("Decisions", decisions)
    section("Actions", actions)
    section("Issues", issues)
    lines.append("")

    section("Artifacts", artifacts)
    lines.append("")

    lines.append("## Key Exchanges")
    lines.append("### User")
    for x in top_snippets(user_items, MAX_USER_ITEMS):
        lines.append(f"- {x}")
    lines.append("### Assistant")
    for x in top_snippets(assistant_items, MAX_ASSISTANT_ITEMS):
        lines.append(f"- {x}")
    lines.append("")

    section("Open Threads", open_threads)
    lines.append("")

    last_user = user_items[-1] if user_items else "(none)"
    last_asst = assistant_items[-1] if assistant_items else "(none)"
    lines.append("## Final Turn")
    lines.append(f"- last_user: {normalize(last_user)}")
    lines.append(f"- last_assistant: {normalize(last_asst)}")
    lines.append("")

    return "\n".join(lines)


def extract_openclaw(jsonl_path: Path) -> dict[str, str]:
    """Extract per-day digests from an OpenClaw session JSONL."""
    buckets: dict[str, dict] = {}

    for raw in jsonl_path.open(errors="replace"):
        try:
            entry = json.loads(raw)
        except json.JSONDecodeError:
            continue

        if entry.get("type") != "message":
            continue

        msg = entry.get("message", {})
        if not msg:
            continue

        role = msg.get("role", "")
        ts = entry.get("timestamp", "")
        dk = date_key(ts)

        if dk not in buckets:
            buckets[dk] = {"user_items": [], "assistant_items": [], "first_ts": "", "last_ts": ""}
        bucket = buckets[dk]
        if ts:
            if not bucket["first_ts"]:
                bucket["first_ts"] = ts
            bucket["last_ts"] = ts

        content = msg.get("content", [])

        if role == "user":
            if isinstance(content, str):
                cleaned = strip_openclaw_meta(content.strip())
                if cleaned:
                    bucket["user_items"].append(cleaned)
            elif isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "text":
                        text = block.get("text", "").strip()
                        cleaned = strip_openclaw_meta(text)
                        if cleaned:
                            bucket["user_items"].append(cleaned)

        elif role == "assistant":
            if isinstance(content, str):
                bucket["assistant_items"].append(content.strip())
            elif isinstance(content, list):
                for block in content:
                    if not isinstance(block, dict):
                        continue
                    btype = block.get("type", "")
                    if btype == "text":
                        text = block.get("text", "").strip()
                        if text:
                            bucket["assistant_items"].append(text)
                    elif btype == "toolCall":
                        name = block.get("name", "unknown")
                        bucket["assistant_items"].append(f"Tool: {name}")

        elif role == "toolResult":
            if isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "text":
                        text = sanitize_tool_output(block.get("text", ""))
                        if should_keep_tool_result(text):
                            bucket["assistant_items"].append(f"Result: {text}")

    digests: dict[str, str] = {}
    for dk, data in buckets.items():
        text = build_digest(
            f"{jsonl_path.stem} [{dk}]",
            data["user_items"],
            data["assistant_items"],
            data["first_ts"],
            data["last_ts"],
        )
        if text:
            digests[dk] = text
    return digests


def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    # Clear old digests
    for md in OUTPUT_DIR.rglob("*.md"):
        md.unlink()

    total_sessions = 0
    total_digests = 0

    for agent_dir in sorted(AGENTS_DIR.iterdir()):
        if not agent_dir.is_dir():
            continue
        sessions_dir = agent_dir / "sessions"
        if not sessions_dir.exists():
            continue

        agent_name = agent_dir.name
        out_dir = OUTPUT_DIR / agent_name

        for jsonl in sessions_dir.glob("*.jsonl"):
            # Skip small files (cron runs, heartbeats)
            if jsonl.stat().st_size < MIN_SESSION_BYTES:
                continue
            # Skip reset/deleted archives
            if ".reset." in jsonl.name or ".deleted." in jsonl.name:
                continue

            total_sessions += 1
            by_day = extract_openclaw(jsonl)

            for dk, text in by_day.items():
                dest = out_dir / f"{jsonl.stem}__{dk}.md"
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_text(text)
                total_digests += 1

    # Stats
    raw_bytes = sum(
        f.stat().st_size
        for f in AGENTS_DIR.rglob("*.jsonl")
        if ".reset." not in f.name and ".deleted." not in f.name
    )
    digest_bytes = sum(f.stat().st_size for f in OUTPUT_DIR.rglob("*.md"))
    raw_mb = raw_bytes / 1024 / 1024
    dig_mb = digest_bytes / 1024 / 1024
    pct = (dig_mb / raw_mb * 100) if raw_mb else 0

    print(f"Sessions: {total_sessions} processed")
    print(f"Digests:  {total_digests} written to {OUTPUT_DIR}")
    print(f"Raw: {raw_mb:.1f} MB → Digests: {dig_mb:.1f} MB ({pct:.0f}%)")


if __name__ == "__main__":
    main()
