---
name: summarize
description: >
  Summarize URLs, YouTube videos, podcasts, audio/video files, and PDFs using the summarize CLI.
  Use when the user shares a link to a video, podcast, article, or PDF and wants a summary or
  analysis. Also useful for extracting transcripts from YouTube or podcast episodes.
metadata: { "openclaw": { "requires": { "bins": ["summarize"] }, "always": false } }
---

# Summarize

Use the `summarize` CLI to extract and summarize content from various sources.

## When This Skill Applies

- User shares a YouTube link and wants a summary or transcript
- User shares a podcast link or RSS feed
- User asks to summarize an article, PDF, or document URL
- User shares an audio or video file for transcription/analysis
- User says "/summarize"

## Usage

Run via the exec tool:

```bash
# URL or article
summarize "https://example.com/article" --length medium

# YouTube video
summarize "https://youtu.be/VIDEO_ID" --youtube auto --length long

# Podcast (RSS feed)
summarize "https://feeds.example.com/podcast.xml" --length medium

# Local file (PDF, audio, video)
summarize "/path/to/file.pdf" --length medium

# Piped content
cat file.txt | summarize - --length short
```

## Options

- `--length short|medium|long|xl|xxl` — controls summary length
- `--model <provider/model>` — override the model (default: auto-selects)
- `--youtube auto` — enable YouTube-specific extraction (transcript + slides)
- `--language <lang>` — output language (default: match source)
- `--extract-only` — just extract content without summarizing

## Models

Uses whichever provider is configured. Examples:

- `--model anthropic/claude-sonnet-4-5` — good balance
- `--model openrouter/google/gemini-3-flash-preview` — fast + cheap
- Default auto mode selects based on content type

## Notes

- YouTube requires yt-dlp and ffmpeg (installed on this VM)
- PDFs work best with Google models
- Audio/video is auto-transcribed then summarized
- Short content is returned as-is (use `--force-summary` to override)
- Text inputs over 10MB are rejected
