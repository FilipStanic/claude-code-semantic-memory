#!/usr/bin/env python3
"""
Auto-extract learnings from a transcript using LLM.

Supports:
- Anthropic API (if ANTHROPIC_API_KEY is set)
- Ollama (if a capable model like llama3, mistral, etc. is available)

Usage: python extract-from-transcript.py <transcript.md> [--daemon-url URL]
"""

import json
import sys
import os
import requests
from pathlib import Path

DAEMON_URL = os.environ.get("CLAUDE_DAEMON_URL", "http://127.0.0.1:8741")

EXTRACTION_PROMPT = """Analyze this Claude Code session transcript and extract learnings that should be remembered for future sessions.

## What to Extract

1. **WORKING_SOLUTION** - Commands, code patterns, or approaches that WORKED after trial and error
2. **GOTCHA** - Counterintuitive behaviors, traps, or "watch out for this" knowledge  
3. **PATTERN** - Recurring architectural decisions or workflows
4. **DECISION** - Explicit design choices and their reasoning
5. **FAILURE** - Things that looked promising but didn't work, and WHY
6. **PREFERENCE** - User's stated preferences for how they want things done

## Rules

1. Be specific - include actual commands, file paths, error messages
2. Prefer solutions over problems - only extract FAILURE if no solution was found
3. Confidence: 0.95+ = confirmed working, 0.85-0.94 = strong evidence, 0.70-0.84 = reasonable inference
4. Skip generic programming knowledge Claude already knows
5. Focus on user-specific infrastructure, preferences, and workflows

## Output Format

Output ONLY valid JSON array, no other text:

[
  {"type": "WORKING_SOLUTION", "content": "specific solution here", "context": "what it solves", "confidence": 0.95},
  {"type": "GOTCHA", "content": "specific gotcha here", "context": "when this applies", "confidence": 0.90}
]

If no learnings are worth extracting, output: []

## Transcript

"""


def extract_with_anthropic(transcript: str) -> list[dict]:
    """Extract learnings using Anthropic API."""
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        return None
    
    try:
        resp = requests.post(
            "https://api.anthropic.com/v1/messages",
            headers={
                "x-api-key": api_key,
                "content-type": "application/json",
                "anthropic-version": "2023-06-01"
            },
            json={
                "model": "claude-sonnet-4-20250514",
                "max_tokens": 4096,
                "messages": [
                    {"role": "user", "content": EXTRACTION_PROMPT + transcript}
                ]
            },
            timeout=120
        )
        resp.raise_for_status()
        
        content = resp.json()["content"][0]["text"]
        # Parse JSON from response
        content = content.strip()
        if content.startswith("```"):
            content = content.split("```")[1]
            if content.startswith("json"):
                content = content[4:]
        
        return json.loads(content)
    except Exception as e:
        print(f"Anthropic API error: {e}", file=sys.stderr)
        return None


def extract_with_ollama(transcript: str, model: str = "llama3") -> list[dict]:
    """Extract learnings using local Ollama model."""
    ollama_url = os.environ.get("OLLAMA_URL", "http://localhost:11434")
    
    try:
        # Check if model is available
        resp = requests.get(f"{ollama_url}/api/tags", timeout=5)
        available_models = [m["name"].split(":")[0] for m in resp.json().get("models", [])]
        
        # Try preferred models in order
        preferred = ["llama3", "mistral", "mixtral", "codellama", "deepseek-coder"]
        selected = None
        for m in preferred:
            if m in available_models:
                selected = m
                break
        
        if not selected and available_models:
            selected = available_models[0]
        
        if not selected:
            print("No Ollama models available", file=sys.stderr)
            return None
        
        print(f"Using Ollama model: {selected}", file=sys.stderr)
        
        resp = requests.post(
            f"{ollama_url}/api/generate",
            json={
                "model": selected,
                "prompt": EXTRACTION_PROMPT + transcript,
                "stream": False,
                "options": {
                    "temperature": 0.3,
                    "num_predict": 4096
                }
            },
            timeout=300  # Local models can be slow
        )
        resp.raise_for_status()
        
        content = resp.json()["response"].strip()
        
        # Try to find JSON array in response
        start = content.find("[")
        end = content.rfind("]") + 1
        if start >= 0 and end > start:
            content = content[start:end]
        
        return json.loads(content)
    except Exception as e:
        print(f"Ollama error: {e}", file=sys.stderr)
        return None


def store_learnings(learnings: list[dict], session_id: str) -> int:
    """Store extracted learnings in the daemon."""
    stored = 0
    
    for learning in learnings:
        if not learning.get("type") or not learning.get("content"):
            continue
        
        # Add session source
        learning["session_source"] = session_id
        
        try:
            resp = requests.post(
                f"{DAEMON_URL}/store",
                json=learning,
                timeout=10
            )
            result = resp.json()
            
            if result.get("status") == "stored":
                stored += 1
                print(f"  ✓ {learning['type']}: {learning['content'][:60]}...", file=sys.stderr)
            elif result.get("status") == "duplicate":
                print(f"  ○ Duplicate: {learning['content'][:40]}...", file=sys.stderr)
        except Exception as e:
            print(f"  ✗ Failed to store: {e}", file=sys.stderr)
    
    return stored


def main():
    if len(sys.argv) < 2:
        print("Usage: python extract-from-transcript.py <transcript.md>", file=sys.stderr)
        sys.exit(1)
    
    transcript_path = Path(sys.argv[1])
    if not transcript_path.exists():
        print(f"File not found: {transcript_path}", file=sys.stderr)
        sys.exit(1)
    
    # Parse daemon URL from args
    global DAEMON_URL
    if "--daemon-url" in sys.argv:
        idx = sys.argv.index("--daemon-url")
        if idx + 1 < len(sys.argv):
            DAEMON_URL = sys.argv[idx + 1]
    
    # Read transcript
    transcript = transcript_path.read_text()
    
    # Truncate if too long (keep first and last parts)
    max_chars = 100000
    if len(transcript) > max_chars:
        half = max_chars // 2
        transcript = transcript[:half] + "\n\n[... transcript truncated ...]\n\n" + transcript[-half:]
    
    # Extract session ID from path
    session_id = transcript_path.parent.name
    
    print(f"Extracting learnings from {transcript_path.name}...", file=sys.stderr)
    
    # Try Anthropic first, then Ollama
    learnings = extract_with_anthropic(transcript)
    
    if learnings is None:
        print("Anthropic API not available, trying Ollama...", file=sys.stderr)
        learnings = extract_with_ollama(transcript)
    
    if learnings is None:
        print("No LLM available for extraction. Set ANTHROPIC_API_KEY or install Ollama.", file=sys.stderr)
        sys.exit(1)
    
    if not learnings:
        print("No learnings extracted from this session.", file=sys.stderr)
        sys.exit(0)
    
    print(f"Extracted {len(learnings)} learnings, storing...", file=sys.stderr)
    
    # Check daemon health
    try:
        resp = requests.get(f"{DAEMON_URL}/health", timeout=2)
        if resp.status_code != 200:
            print(f"Daemon not healthy at {DAEMON_URL}", file=sys.stderr)
            # Output learnings to stdout as fallback
            print(json.dumps(learnings, indent=2))
            sys.exit(1)
    except:
        print(f"Daemon not reachable at {DAEMON_URL}", file=sys.stderr)
        print(json.dumps(learnings, indent=2))
        sys.exit(1)
    
    stored = store_learnings(learnings, session_id)
    print(f"\nStored {stored}/{len(learnings)} learnings", file=sys.stderr)


if __name__ == "__main__":
    main()
