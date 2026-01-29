#!/bin/bash
#
# PreCompact Hook - Auto-export, convert, and extract learnings
#
# This hook fires when Claude Code is about to compact the context window.
# It preserves the full session by:
# 1. Exporting the raw JSONL transcript
# 2. Converting to readable markdown
# 3. Auto-extracting learnings using LLM (Anthropic API or Ollama)
# 4. Storing learnings in the semantic memory database
#
# Install: cp pre-compact.sh ~/.claude/hooks/PreCompact.sh
#          chmod +x ~/.claude/hooks/PreCompact.sh
#
# Requirements:
# - ANTHROPIC_API_KEY env var, OR
# - Ollama running with llama3/mistral/etc.

set -euo pipefail

# Configuration
DAEMON_HOST="${CLAUDE_DAEMON_HOST:-127.0.0.1}"
DAEMON_PORT="${CLAUDE_DAEMON_PORT:-8741}"
DAEMON_URL="http://${DAEMON_HOST}:${DAEMON_PORT}"
TRANSCRIPTS_DIR="${HOME}/.claude/transcripts"
SCRIPTS_DIR="${CLAUDE_MEMORY_SCRIPTS:-${HOME}/.claude/memory-scripts}"

# Read input from stdin
INPUT=$(cat)

# Extract session info
SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('sessionId','unknown'))" 2>/dev/null || echo "unknown")
TRANSCRIPT_PATH=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('transcriptPath',''))" 2>/dev/null || echo "")
PROJECT_PATH=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null || echo "")

if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
    echo "No transcript found, skipping" >&2
    exit 0
fi

# Create output directory
SESSION_DIR="${TRANSCRIPTS_DIR}/${SESSION_ID}"
mkdir -p "$SESSION_DIR"

# 1. Copy raw transcript
cp "$TRANSCRIPT_PATH" "${SESSION_DIR}/transcript.jsonl"
echo "✓ Exported transcript" >&2

# 2. Convert to markdown
python3 << 'CONVERT_SCRIPT' "$SESSION_DIR"
import json
import sys
from pathlib import Path
from datetime import datetime

session_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".")
jsonl_path = session_dir / "transcript.jsonl"
md_path = session_dir / "transcript.md"

messages = []
session_id = "unknown"
project_path = ""

with open(jsonl_path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
            
            if entry.get('sessionId'):
                session_id = entry['sessionId']
            if entry.get('cwd'):
                project_path = entry['cwd']
            
            role = entry.get('type') or entry.get('role')
            
            if role == 'user':
                content = entry.get('message', {}).get('content') or entry.get('content') or entry.get('text') or ''
                if isinstance(content, str) and content.strip():
                    messages.append({'role': 'user', 'content': content})
            
            elif role == 'assistant':
                assistant_content = ''
                thinking_content = ''
                
                content = entry.get('message', {}).get('content') or entry.get('content')
                
                if isinstance(content, list):
                    for block in content:
                        if block.get('type') == 'thinking':
                            thinking_content += block.get('thinking', '')
                        elif block.get('type') == 'text':
                            assistant_content += block.get('text', '')
                elif isinstance(content, str):
                    assistant_content = content
                
                if entry.get('thinking'):
                    thinking_content = entry['thinking']
                
                if thinking_content.strip() or assistant_content.strip():
                    messages.append({
                        'role': 'assistant',
                        'thinking': thinking_content.strip() or None,
                        'content': assistant_content.strip()
                    })
                    
        except json.JSONDecodeError:
            continue

# Write markdown
with open(md_path, 'w') as f:
    f.write(f"# Session Transcript\n\n")
    f.write(f"**Session ID**: {session_id}\n")
    f.write(f"**Project**: {project_path}\n")
    f.write(f"**Exported**: {datetime.now().isoformat()}\n\n")
    f.write("---\n\n")
    
    for msg in messages:
        if msg['role'] == 'user':
            f.write(f"## 👤 User\n\n{msg['content']}\n\n")
        elif msg['role'] == 'assistant':
            f.write("## 🤖 Assistant\n\n")
            if msg.get('thinking'):
                f.write(f"<details>\n<summary>💭 Thinking</summary>\n\n{msg['thinking']}\n\n</details>\n\n")
            if msg.get('content'):
                f.write(f"{msg['content']}\n\n")
        f.write("---\n\n")

print(f"Converted {len(messages)} messages", file=sys.stderr)
CONVERT_SCRIPT
echo "✓ Converted to markdown" >&2

# 3. Auto-extract learnings using LLM
EXTRACT_SCRIPT="${SCRIPTS_DIR}/extract-from-transcript.py"
if [ -f "$EXTRACT_SCRIPT" ]; then
    echo "Extracting learnings..." >&2
    python3 "$EXTRACT_SCRIPT" "${SESSION_DIR}/transcript.md" --daemon-url "$DAEMON_URL" || {
        echo "⚠️  Learning extraction failed (LLM not available?)" >&2
    }
else
    echo "⚠️  Extract script not found at $EXTRACT_SCRIPT" >&2
    echo "   Skipping auto-extraction. Run manually later." >&2
fi

# 4. Write metadata
python3 << 'META_SCRIPT' "$SESSION_DIR" "$SESSION_ID" "$PROJECT_PATH"
import json
import sys
from pathlib import Path
from datetime import datetime

session_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".")
session_id = sys.argv[2] if len(sys.argv) > 2 else "unknown"
project_path = sys.argv[3] if len(sys.argv) > 3 else ""

metadata = {
    'session_id': session_id,
    'project_path': project_path,
    'compacted_at': datetime.now().isoformat(),
    'files': ['transcript.jsonl', 'transcript.md']
}

with open(session_dir / "metadata.json", 'w') as f:
    json.dump(metadata, f, indent=2)

print(f"Wrote metadata", file=sys.stderr)
META_SCRIPT
echo "✓ Wrote metadata" >&2

echo "" >&2
echo "Session preserved to: ${SESSION_DIR}" >&2
