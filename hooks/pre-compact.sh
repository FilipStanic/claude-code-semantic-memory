#!/bin/bash
#
# PreCompact Hook - Auto-export, convert, and dispatch sub-agent for extraction
#
# This hook fires when Claude Code is about to compact the context window.
# It preserves the full session by:
# 1. Exporting the raw JSONL transcript
# 2. Converting to readable markdown
# 3. Outputting instructions for Claude to dispatch a sub-agent to extract learnings
#
# The sub-agent reads the transcript, extracts learnings, and stores them
# in the semantic memory database via the daemon API.
#
# Install: cp pre-compact.sh ~/.claude/hooks/PreCompact.sh
#          chmod +x ~/.claude/hooks/PreCompact.sh

set -euo pipefail

# Configuration
DAEMON_HOST="${CLAUDE_DAEMON_HOST:-127.0.0.1}"
DAEMON_PORT="${CLAUDE_DAEMON_PORT:-8741}"
DAEMON_URL="http://${DAEMON_HOST}:${DAEMON_PORT}"
TRANSCRIPTS_DIR="${HOME}/.claude/transcripts"

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
python3 - "$SESSION_DIR" << 'CONVERT_SCRIPT'
import json
import sys
from pathlib import Path
from datetime import datetime

session_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".")
jsonl_path = session_dir / "transcript.jsonl"
md_path = session_dir / "transcript.md"

messages = []
session_id = session_dir.name
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
            f.write(f"## User\n\n{msg['content']}\n\n")
        elif msg['role'] == 'assistant':
            f.write("## Assistant\n\n")
            if msg.get('thinking'):
                f.write(f"<thinking>\n{msg['thinking']}\n</thinking>\n\n")
            if msg.get('content'):
                f.write(f"{msg['content']}\n\n")
        f.write("---\n\n")

print(f"Converted {len(messages)} messages", file=sys.stderr)
CONVERT_SCRIPT

echo "✓ Converted to markdown" >&2

# 3. Write metadata
cat > "${SESSION_DIR}/metadata.json" << METADATA
{
    "session_id": "${SESSION_ID}",
    "project_path": "${PROJECT_PATH}",
    "exported_at": "$(date -Iseconds)",
    "transcript_path": "${SESSION_DIR}/transcript.md",
    "daemon_url": "${DAEMON_URL}",
    "status": "pending_extraction"
}
METADATA
echo "✓ Wrote metadata" >&2

echo "" >&2
echo "═══════════════════════════════════════════════════════════════" >&2
echo "Session transcript exported to: ${SESSION_DIR}/transcript.md" >&2
echo "═══════════════════════════════════════════════════════════════" >&2
echo "" >&2

# 4. Output context for Claude to dispatch sub-agent
# This appears in Claude's context after compaction
cat << SUBAGENT_INSTRUCTION

<pre-compact-extraction-required>
Session transcript has been exported and needs learning extraction.

TRANSCRIPT PATH: ${SESSION_DIR}/transcript.md
SESSION ID: ${SESSION_ID}
DAEMON URL: ${DAEMON_URL}

Dispatch a sub-agent using the Task tool with this prompt:

---
Read the transcript at ${SESSION_DIR}/transcript.md and extract learnings to store in the semantic memory database.

For each learning you find, store it by running:
curl -X POST ${DAEMON_URL}/store -H "Content-Type: application/json" -d '{"type": "<TYPE>", "content": "<LEARNING>", "context": "<CONTEXT>", "confidence": <SCORE>, "session_source": "${SESSION_ID}"}'

LEARNING TYPES:
- WORKING_SOLUTION: Commands, code, or approaches that worked
- GOTCHA: Traps, counterintuitive behaviors, "watch out for this"
- PATTERN: Recurring architectural decisions or workflows  
- DECISION: Explicit design choices with reasoning
- FAILURE: What didn't work and why
- PREFERENCE: User's stated preferences

RULES:
- Be specific - include actual commands, paths, error messages
- Confidence 0.95+ for explicitly confirmed, 0.85+ for strong evidence
- Skip generic programming knowledge Claude already knows
- Skip incomplete thoughts and debugging noise
- Focus on user-specific infrastructure, preferences, workflows
---

</pre-compact-extraction-required>

SUBAGENT_INSTRUCTION
