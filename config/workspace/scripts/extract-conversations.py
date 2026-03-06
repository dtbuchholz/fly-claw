#!/usr/bin/env python3
"""Extract full conversations from OpenClaw session JSONL files.

Preserves the actual user/assistant dialogue flow, stripping only:
- Tool calls and tool results
- Thinking/reasoning blocks
- System messages and metadata headers (untrusted metadata, sender blocks)
- Noise (HEARTBEAT_OK, NO_REPLY, ANNOUNCE_SKIP, compaction flushes)

Output: one markdown file per session-day at:
  <OUTPUT_DIR>/<agent>/<session-id>__YYYY-MM-DD.md

Designed for QMD indexing — the full conversation is searchable, but
without the tool-call spam that dominates raw JSONL.
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

# Sessions smaller than this are likely cron runs — skip them
MIN_SESSION_BYTES = 10_000

# --- Noise patterns to skip entirely ---
SKIP_PATTERNS = [
    re.compile(r"^\s*NO_REPLY\s*$", re.IGNORECASE),
    re.compile(r"^\s*HEARTBEAT_OK\s*$", re.IGNORECASE),
    re.compile(r"^\s*ANNOUNCE_SKIP\s*$", re.IGNORECASE),
    re.compile(r"^Pre-compaction memory flush", re.IGNORECASE),
]

# Strip OpenClaw metadata headers from user messages
METADATA_PATTERNS = [
    # Conversation info block
    re.compile(
        r'Conversation info \(untrusted metadata\):\s*```json\s*\{[^}]*\}\s*```\s*',
        re.DOTALL,
    ),
    # Sender block
    re.compile(
        r'Sender \(untrusted metadata\):\s*```json\s*\{[^}]*\}\s*```\s*',
        re.DOTALL,
    ),
    # Audio transcript header
    re.compile(
        r'\[Audio\]\s*User text:\s*\[Telegram[^\]]*\]\s*(?:<media:\w+>\s*)?Transcript:\s*',
        re.DOTALL,
    ),
    # Standalone [Audio] tag
    re.compile(r'^\[Audio\]\s*', re.MULTILINE),
    # System message lines
    re.compile(r'^\[.*?\] \[System Message\].*$', re.MULTILINE),
    re.compile(r'^System: \[.*?\].*$', re.MULTILINE),
]

ANSI_RE = re.compile(r"\x1B\[[0-?]*[ -/]*[@-~]")


def strip_metadata(text: str) -> str:
    """Remove OpenClaw metadata headers, keep actual user content."""
    t = text
    for pat in METADATA_PATTERNS:
        t = pat.sub("", t)
    t = ANSI_RE.sub("", t)
    return t.strip()


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
        # Skip: toolCall, toolResult, thinking, redactedThinking, etc.

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


def extract_conversation(jsonl_path: Path) -> dict[str, str]:
    """Extract per-day conversation transcripts from a session JSONL."""
    buckets: dict[str, list[str]] = {}
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

        # Only keep user and assistant messages
        if role not in ("user", "assistant"):
            continue

        text = extract_text_content(msg.get("content", []))
        if not text:
            continue

        # Strip metadata from user messages
        if role == "user":
            text = strip_metadata(text)

        if should_skip(text):
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
        time_str = format_timestamp(ts)
        prefix = f"[{time_str}] " if time_str else ""

        if role == "user":
            buckets[dk].append(f"{prefix}**Dan:** {text}")
        else:
            buckets[dk].append(f"{prefix}**Tars:** {text}")

    # Build markdown files
    digests: dict[str, str] = {}
    for dk, turns in buckets.items():
        meta = bucket_meta[dk]
        if not turns:
            continue

        lines = [
            f"# {jsonl_path.stem} [{dk}]",
            "",
            f"- Period: {meta['first_ts']} → {meta['last_ts']}",
            f"- Messages: {meta['user_count']} user, {meta['assistant_count']} assistant",
            "",
            "---",
            "",
        ]
        lines.extend(turns)
        lines.append("")
        digests[dk] = "\n\n".join(lines)

    return digests


def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

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

        for jsonl in sessions_dir.glob("*.jsonl"):
            if jsonl.stat().st_size < MIN_SESSION_BYTES:
                continue
            if ".reset." in jsonl.name or ".deleted." in jsonl.name:
                continue
            if is_cron_session(jsonl):
                continue

            total_sessions += 1
            by_day = extract_conversation(jsonl)

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
