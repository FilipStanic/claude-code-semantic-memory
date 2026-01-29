#!/bin/bash
#
# SessionStart Hook - Initialize session and check daemon health
#
# This hook fires once when a Claude Code session begins. It:
# 1. Checks if the memory daemon is running
# 2. Optionally starts it if running locally
# 3. Warns about any orphaned transcripts from crashed sessions
#
# Install: cp session-start.sh ~/.claude/hooks/SessionStart.sh
#          chmod +x ~/.claude/hooks/SessionStart.sh

set -euo pipefail

# Configuration
DAEMON_HOST="${CLAUDE_DAEMON_HOST:-127.0.0.1}"
DAEMON_PORT="${CLAUDE_DAEMON_PORT:-8741}"
DAEMON_URL="http://${DAEMON_HOST}:${DAEMON_PORT}"
TRANSCRIPTS_DIR="${HOME}/.claude/transcripts"
DAEMON_DIR="${CLAUDE_DAEMON_DIR:-}"  # Set this to auto-start daemon

# Read input from stdin (contains session info)
INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('sessionId','unknown'))" 2>/dev/null || echo "unknown")

# Check for orphaned transcripts (sessions that crashed before completing)
if [ -d "$TRANSCRIPTS_DIR" ]; then
    ORPHANS=$(find "$TRANSCRIPTS_DIR" -maxdepth 1 -type d -mmin +60 -newer "$TRANSCRIPTS_DIR" 2>/dev/null | wc -l)
    if [ "$ORPHANS" -gt 0 ]; then
        echo "⚠️  Found $ORPHANS potentially orphaned transcript(s) in $TRANSCRIPTS_DIR" >&2
        echo "   These may be from crashed sessions. Review and process manually." >&2
    fi
fi

# Check daemon health
DAEMON_STATUS="unknown"
if curl -s --max-time 2 "${DAEMON_URL}/health" > /dev/null 2>&1; then
    DAEMON_STATUS="running"
else
    DAEMON_STATUS="not_running"
    
    # Try to start daemon if we're on the local machine and know where it is
    if [ "$DAEMON_HOST" = "127.0.0.1" ] && [ -n "$DAEMON_DIR" ] && [ -f "${DAEMON_DIR}/server.py" ]; then
        echo "Starting memory daemon..." >&2
        cd "$DAEMON_DIR"
        nohup python3 server.py > daemon.log 2>&1 &
        
        # Wait for startup
        for i in {1..10}; do
            sleep 1
            if curl -s --max-time 1 "${DAEMON_URL}/health" > /dev/null 2>&1; then
                DAEMON_STATUS="started"
                echo "✓ Memory daemon started" >&2
                break
            fi
        done
        
        if [ "$DAEMON_STATUS" != "started" ]; then
            echo "⚠️  Failed to start memory daemon" >&2
        fi
    else
        echo "⚠️  Memory daemon not running at ${DAEMON_URL}" >&2
        echo "   Start it with: cd <daemon-dir> && python3 server.py" >&2
    fi
fi

# Output session info (optional - for logging/debugging)
# Uncomment to see session details:
# echo "Session: $SESSION_ID | Daemon: $DAEMON_STATUS" >&2
