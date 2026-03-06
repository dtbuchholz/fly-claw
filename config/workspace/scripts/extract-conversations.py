#!/usr/bin/env python3
"""Extract full conversations from OpenClaw session JSONL files.

Preserves the actual user/assistant dialogue flow, stripping only:
- Tool calls and tool results
- Thinking/reasoning blocks
- System messages and metadata headers (untrusted metadata, sender blocks)
- Noise (HEARTBEAT_OK, NO_REPLY, ANNOUNCE_SKIP, compaction flushes)

Output structure (one per session-day):
  Full transcripts (primary, indexed by QMD):
    <OUTPUT_DIR>/<agent>/<session-id>__YYYY-MM-DD.md
  Summaries (sidecar, also indexed):
    <OUTPUT_DIR>/summaries/<agent>/<session-id>__YYYY-MM-DD.md
"""

import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

# --- Config ---
OPENCLAW_DIR = Path(sys.argv[1] if len(sys.argv) > 1 else "/data/.openclaw")
AGENTS_DIR = OPENCLAW_DIR / "agents"
OUTPUT_DIR = OPENCLAW_DIR / "conversations"
SUMMARY_DIR = OUTPUT_DIR / "summaries"

# Sessions smaller than this are likely cron runs — skip them
MIN_SESSION_BYTES = 10_000

# Per-message character limit for full transcripts.
# Messages beyond this are truncated. Prevents massive code dumps / diffs
# from bloating the index with no retrieval value.
MAX_MESSAGE_CHARS = 8000

# Summary limits
MAX_SUMMARY_ITEMS = 8
MAX_SUMMARY_TEXT_CHARS = 420

# --- Noise patterns (line-level filtering) ---
NOISE_LINE_PATTERNS = [
    re.compile(r"^<environment_context>", re.IGNORECASE),
    re.compile(r"^Project Guidelines \(from .*?\)", re.IGNORECASE),
    re.compile(r"^Compact Instructions", re.IGNORECASE),
    re.compile(r"^Chunk ID:\s", re.IGNORECASE),
    re.compile(r"^Wall time:\s", re.IGNORECASE),
    re.compile(r"^Process exited with code\s", re.IGNORECASE),
    re.compile(r"^Original token count:\s", re.IGNORECASE),
    re.compile(r"^Output:\s*$", re.IGNORECASE),
    re.compile(r"^Tool result:\s*", re.IGNORECASE),
    re.compile(r"^<analysis>", re.IGNORECASE),
    re.compile(r"^</analysis>", re.IGNORECASE),
    re.compile(r"compaction flush", re.IGNORECASE),
]

# Message-level skip patterns
SKIP_PATTERNS = [
    re.compile(r"^\s*NO_REPLY\s*$", re.IGNORECASE),
    re.compile(r"^\s*HEARTBEAT_OK\s*$", re.IGNORECASE),
    re.compile(r"^\s*ANNOUNCE_SKIP\s*$", re.IGNORECASE),
    re.compile(r"^Pre-compaction memory flush", re.IGNORECASE),
]

# Strip OpenClaw metadata headers from user messages
METADATA_PATTERNS = [
    re.compile(
        r'Conversation info \(untrusted metadata\):\s*```json\s*\{[^}]*\}\s*```\s*',
        re.DOTALL,
    ),
    re.compile(
        r'Sender \(untrusted metadata\):\s*```json\s*\{[^}]*\}\s*```\s*',
        re.DOTALL,
    ),
    re.compile(
        r'\[Audio\]\s*User text:\s*\[Telegram[^\]]*\]\s*(?:<media:\w+>\s*)?Transcript:\s*',
        re.DOTALL,
    ),
    re.compile(r'^\[Audio\]\s*', re.MULTILINE),
    re.compile(r'^\[.*?\] \[System Message\].*$', re.MULTILINE),
    re.compile(r'^System: \[.*?\].*$', re.MULTILINE),
]

ANSI_RE = re.compile(r"\x1B\[[0-?]*[ -/]*[@-~]")

# --- Summary hint tuples ---
SIGNAL_HINTS = (
    "fixed", "added", "updated", "implemented", "created", "removed",
    "verified", "committed", "merged", "completed", "passed", "blocked",
    "failed", "error", "issue", "plan", "decision", "tradeoff",
)
QUESTION_STARTERS = (
    "what ", "how ", "why ", "when ", "where ", "who ", "which ",
    "can ", "could ", "should ", "would ", "did ", "is ", "are ", "do ", "does ",
)
DECISION_HINTS = (
    "decide", "decision", "recommend", "best approach", "tradeoff",
    "we should", "let's", "instead",
)
ACTION_HINTS = (
    "added", "updated", "implemented", "created", "removed", "renamed",
    "fixed", "tested", "verified", "committed", "pushed", "configured",
    "installed", "deployed",
)
ISSUE_HINTS = (
    "error", "failed", "leak", "blocked", "problem", "issue",
    "mismatch", "not found", "cannot", "can't", "broken", "bug",
)
OPEN_HINTS = (
    "next step", "next steps", "follow-up", "todo", "to do",
    "pending", "later", "can you", "should we", "want me to",
)
PLAUSIBLE_PATH_RE = re.compile(
    r"(~?/[\w\-.~/]+|[\w\-.]+/[\w\-.~/]+|[\w\-.]+\.(md|py|ts|tsx|js|json|toml|sh|yaml|yml))"
)


def strip_metadata(text: str) -> str:
    """Remove OpenClaw metadata headers, keep actual user content."""
    t = text
    for pat in METADATA_PATTERNS:
        t = pat.sub("", t)
    t = ANSI_RE.sub("", t)
    return t.strip()


def normalize_text(text: str) -> str:
    """Clean text with line-level noise filtering and character cap."""
    t = ANSI_RE.sub("", text).replace("\r\n", "\n").replace("\r", "\n")
    clean_lines: list[str] = []
    for raw in t.splitlines():
        line = raw.rstrip()
        if not line:
            clean_lines.append("")
            continue
        if any(p.search(line.strip()) for p in NOISE_LINE_PATTERNS):
            continue
        clean_lines.append(line)
    t = "\n".join(clean_lines).strip()
    if len(t) > MAX_MESSAGE_CHARS:
        t = t[:MAX_MESSAGE_CHARS].rstrip() + "\n[...truncated]"
    return t


def should_skip(text: str) -> bool:
    """Check if a message is pure noise."""
    t = text.strip()
    if not t:
        return True
    return any(p.match(t) for p in SKIP_PATTERNS)


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


def format_timestamp(ts: str) -> str:
    dt = parse_timestamp(ts)
    return dt.strftime("%H:%M UTC") if dt else ""


def date_key(ts: str) -> str:
    dt = parse_timestamp(ts)
    return dt.strftime("%Y-%m-%d") if dt else "undated"


def extract_text_content(content) -> str:
    """Extract only text content from a message, skipping tool calls and thinking."""
    if isinstance(content, str):
        return content.strip()
    if not isinstance(content, list):
        return ""
    parts = []
    for block in content:
        if not isinstance(block, dict):
            continue
        btype = block.get("type", "")
        if btype == "text":
            text = block.get("text", "").strip()
            if text:
                parts.append(text)
    return "\n\n".join(parts)


def is_cron_session(jsonl_path: Path) -> bool:
    """Detect cron sessions by checking the first user message for [cron:] prefix."""
    try:
        for raw in jsonl_path.open(errors="replace"):
            try:
                entry = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if entry.get("type") != "message":
                continue
            msg = entry.get("message", {})
            if not msg or msg.get("role") != "user":
                continue
            text = extract_text_content(msg.get("content", []))
            return text.startswith("[cron:")
    except OSError:
        pass
    return False


# --- Summary helpers ---

def contains_any(text: str, hints: tuple[str, ...]) -> bool:
    t = text.lower()
    return any(h in t for h in hints)


def signal_score(text: str) -> int:
    t = text.lower()
    score = 0
    if any(h in t for h in SIGNAL_HINTS):
        score += 2
    if "/" in text or any(ext in text for ext in (".md", ".ts", ".py", ".json", ".sh")):
        score += 1
    if "```" in text or any(cmd in t for cmd in ("git ", "npm ", "qmd ", "make ")):
        score += 1
    if 40 <= len(text) <= MAX_SUMMARY_TEXT_CHARS:
        score += 1
    return score


def top_snippets(items: list[str], max_items: int) -> list[str]:
    seen: set[str] = set()
    unique = []
    for item in items:
        normed = " ".join(item.strip().split())
        if len(normed) > MAX_SUMMARY_TEXT_CHARS:
            normed = normed[:MAX_SUMMARY_TEXT_CHARS].rstrip() + "..."
        if normed and normed not in seen:
            seen.add(normed)
            unique.append(normed)
    ranked = sorted(unique, key=signal_score, reverse=True)
    strong = [x for x in ranked if signal_score(x) >= 1]
    return (strong or ranked)[:max_items]


def extract_artifacts(items: list[str]) -> list[str]:
    artifacts: list[str] = []
    for item in items:
        for m in PLAUSIBLE_PATH_RE.findall(item):
            token = m[0] if isinstance(m, tuple) else m
            if token:
                artifacts.append(token.strip(".,:;"))
    seen: set[str] = set()
    unique = []
    for a in artifacts:
        if a not in seen:
            seen.add(a)
            unique.append(a)
    return unique[:MAX_SUMMARY_ITEMS]


def build_summary(
    label: str,
    user_items: list[str],
    assistant_items: list[str],
    first_ts: str,
    last_ts: str,
) -> str:
    """Build a compact summary sidecar."""
    # Categorize user messages
    goals, questions = [], []
    for item in user_items:
        low = item.lower().strip()
        if "?" in item or low.startswith(QUESTION_STARTERS):
            questions.append(item)
        goals.append(item)

    # Categorize assistant messages
    decisions, actions, issues, open_threads = [], [], [], []
    for item in assistant_items:
        if contains_any(item, DECISION_HINTS):
            decisions.append(item)
        if contains_any(item, ACTION_HINTS):
            actions.append(item)
        if contains_any(item, ISSUE_HINTS):
            issues.append(item)
        if contains_any(item, OPEN_HINTS):
            open_threads.append(item)

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
        snips = top_snippets(items, MAX_SUMMARY_ITEMS)
        if snips:
            lines.extend(f"- {x}" for x in snips)
        else:
            lines.append("- (none)")

    lines.append("## User Intent")
    section("Goals", goals)
    section("Questions", questions)
    lines.append("")

    lines.append("## Assistant Work")
    section("Decisions", decisions)
    section("Actions", actions)
    section("Issues", issues)
    lines.append("")

    section("Open Threads", open_threads)
    lines.append("")

    lines.append("## Artifacts")
    if artifacts:
        lines.extend(f"- {a}" for a in artifacts)
    else:
        lines.append("- (none)")
    lines.append("")

    lines.append("## Final Turn")
    last_user = user_items[-1] if user_items else "(none)"
    last_asst = assistant_items[-1] if assistant_items else "(none)"
    lu = " ".join(last_user.split())
    la = " ".join(last_asst.split())
    if len(lu) > MAX_SUMMARY_TEXT_CHARS:
        lu = lu[:MAX_SUMMARY_TEXT_CHARS] + "..."
    if len(la) > MAX_SUMMARY_TEXT_CHARS:
        la = la[:MAX_SUMMARY_TEXT_CHARS] + "..."
    lines.append(f"- last_user: {lu}")
    lines.append(f"- last_assistant: {la}")
    lines.append("")

    return "\n".join(lines)


# --- Main extraction ---

def extract_conversation(jsonl_path: Path) -> dict[str, dict[str, str]]:
    """Extract per-day full transcripts + summary sidecars from a session JSONL."""
    buckets: dict[str, list[dict]] = {}
    bucket_meta: dict[str, dict] = {}

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

        if role not in ("user", "assistant"):
            continue

        text = extract_text_content(msg.get("content", []))
        if not text:
            continue

        if role == "user":
            text = strip_metadata(text)

        if should_skip(text):
            continue

        # Apply line-level noise filtering and character cap
        text = normalize_text(text)
        if not text:
            continue

        if dk not in buckets:
            buckets[dk] = []
            bucket_meta[dk] = {"first_ts": "", "last_ts": "", "user_count": 0, "assistant_count": 0}

        meta = bucket_meta[dk]
        if ts:
            if not meta["first_ts"]:
                meta["first_ts"] = ts
            meta["last_ts"] = ts

        meta[f"{role}_count"] = meta.get(f"{role}_count", 0) + 1
        buckets[dk].append({"role": role, "text": text, "ts": ts})

    results: dict[str, dict[str, str]] = {}
    for dk, events in buckets.items():
        meta = bucket_meta[dk]
        if not events:
            continue

        # Build full transcript with adjacent dedup
        transcript_lines = [
            f"# {jsonl_path.stem} [{dk}]",
            "",
            f"- Period: {meta['first_ts']} → {meta['last_ts']}",
            f"- Messages: {meta['user_count']} user, {meta['assistant_count']} assistant",
            "",
            "---",
            "",
        ]

        prev_key: Optional[tuple[str, str]] = None
        user_items: list[str] = []
        assistant_items: list[str] = []

        for ev in events:
            role = ev["role"]
            text = ev["text"]
            ts = ev["ts"]

            # Adjacent dedup
            key = (role, text)
            if key == prev_key:
                continue
            prev_key = key

            time_str = format_timestamp(ts)
            prefix = f"[{time_str}] " if time_str else ""

            if role == "user":
                transcript_lines.append(f"{prefix}**Dan:** {text}")
                user_items.append(text)
            else:
                transcript_lines.append(f"{prefix}**Tars:** {text}")
                assistant_items.append(text)

            transcript_lines.append("")

        full_text = "\n".join(transcript_lines)

        # Build summary sidecar
        summary_text = build_summary(
            f"{jsonl_path.stem} [{dk}]",
            user_items,
            assistant_items,
            meta["first_ts"],
            meta["last_ts"],
        )

        results[dk] = {"full": full_text, "summary": summary_text}

    return results


def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    SUMMARY_DIR.mkdir(parents=True, exist_ok=True)

    # Clear old digests
    for md in OUTPUT_DIR.rglob("*.md"):
        md.unlink()

    if not AGENTS_DIR.exists():
        print(f"No agents directory found at {AGENTS_DIR}; nothing to index.")
        return

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
        sum_dir = SUMMARY_DIR / agent_name

        for jsonl in sessions_dir.glob("*.jsonl"):
            if jsonl.stat().st_size < MIN_SESSION_BYTES:
                continue
            if ".reset." in jsonl.name or ".deleted." in jsonl.name:
                continue
            if is_cron_session(jsonl):
                continue

            total_sessions += 1
            by_day = extract_conversation(jsonl)

            for dk, payload in by_day.items():
                fname = f"{jsonl.stem}__{dk}.md"

                dest = out_dir / fname
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_text(payload["full"])

                sdest = sum_dir / fname
                sdest.parent.mkdir(parents=True, exist_ok=True)
                sdest.write_text(payload["summary"])

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
