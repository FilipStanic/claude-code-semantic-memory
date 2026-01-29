#!/usr/bin/env python3
"""
Import learnings from JSONL file into the memory database.

Usage: python import-learnings.py <path-to-learnings.jsonl>
"""

import json
import sys
import requests
from pathlib import Path

DAEMON_URL = "http://localhost:8741"

def main():
    if len(sys.argv) < 2:
        print("Usage: python import-learnings.py <path-to-learnings.jsonl>")
        sys.exit(1)
    
    jsonl_path = Path(sys.argv[1])
    
    if not jsonl_path.exists():
        print(f"File not found: {jsonl_path}")
        sys.exit(1)
    
    # Check daemon health
    try:
        resp = requests.get(f"{DAEMON_URL}/health", timeout=2)
        if resp.status_code != 200:
            print("Memory daemon not healthy. Start it with: python daemon/server.py")
            sys.exit(1)
    except requests.exceptions.ConnectionError:
        print("Cannot connect to memory daemon. Start it with: python daemon/server.py")
        sys.exit(1)
    
    # Process each line
    imported = 0
    duplicates = 0
    errors = 0
    
    with open(jsonl_path) as f:
        for line_num, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            
            try:
                learning = json.loads(line)
            except json.JSONDecodeError as e:
                print(f"Line {line_num}: Invalid JSON - {e}")
                errors += 1
                continue
            
            # Validate required fields
            if "type" not in learning or "content" not in learning:
                print(f"Line {line_num}: Missing required fields (type, content)")
                errors += 1
                continue
            
            # Store in daemon
            try:
                resp = requests.post(
                    f"{DAEMON_URL}/store",
                    json=learning,
                    timeout=10
                )
                result = resp.json()
                
                if result.get("status") == "stored":
                    imported += 1
                    print(f"✓ {learning['type']}: {learning['content'][:60]}...")
                elif result.get("status") == "duplicate":
                    duplicates += 1
                    print(f"○ Duplicate (sim={result['similarity']:.2f}): {learning['content'][:40]}...")
                else:
                    print(f"✗ Line {line_num}: {result}")
                    errors += 1
                    
            except Exception as e:
                print(f"✗ Line {line_num}: Request failed - {e}")
                errors += 1
    
    print("\n" + "=" * 50)
    print(f"Imported: {imported}")
    print(f"Duplicates skipped: {duplicates}")
    print(f"Errors: {errors}")
    
    # Show final stats
    stats = requests.get(f"{DAEMON_URL}/stats").json()
    print(f"\nTotal learnings in database: {stats['total_learnings']}")
    print(f"By type: {json.dumps(stats['by_type'], indent=2)}")

if __name__ == "__main__":
    main()
