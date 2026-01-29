# Learning Extraction Prompt

Use this prompt in a Claude Code session to extract learnings from your converted transcripts.

## Prerequisites

1. Convert your `.jsonl` transcripts to markdown using `scripts/jsonl-to-markdown.js`
2. Save all converted `.md` files in a single folder (e.g., `~/converted-transcripts/`)

## The Prompt

Copy everything below the line and paste it into a new Claude Code session:

---

I need you to analyze all my Claude Code session transcripts in `~/converted-transcripts/` and extract learnings that should be stored in a semantic memory database. These memories will be embedded and retrieved during future sessions to prevent me from having to rediscover solutions.

## Your Approach

1. First, list all .md files in the `~/converted-transcripts/` directory
2. Process them in batches of 5 files at a time using sub-agents (Task tool)
3. Each sub-agent reads its assigned transcript and extracts learnings
4. Collect all results and deduplicate across sessions
5. Output the final consolidated learnings to `~/extracted-learnings.jsonl`

## Sub-Agent Instructions

For each batch, dispatch 5 parallel sub-agents with this instruction:

"Read the transcript at [FILE_PATH] and extract learnings. Output ONLY valid JSONL (one JSON object per line) with no additional text. Follow the learning type definitions and rules exactly."

## What to Extract

1. **WORKING_SOLUTION** - Commands, code patterns, or approaches that WORKED after trial and error
2. **GOTCHA** - Counterintuitive behaviors, traps, or "watch out for this" knowledge
3. **PATTERN** - Recurring architectural decisions or workflows
4. **DECISION** - Explicit design choices and their reasoning
5. **FAILURE** - Things that looked promising but didn't work, and WHY
6. **PREFERENCE** - User's stated preferences for how they want things done

## Output Format

For EACH learning, output in this exact JSON format (one per line, JSONL style):

```json
{"type": "WORKING_SOLUTION", "content": "To invoke PowerShell remotely over Tailscale, use: $cred = Import-Clixml -Path '$env:USERPROFILE\\.claude\\cred.xml'; Invoke-Command -ComputerName 100.95.72.101 -Credential $cred -ScriptBlock { <commands> }", "context": "PowerShell remoting", "confidence": 0.95, "session_source": "session-abc123"}
```

```json
{"type": "GOTCHA", "content": "Running inline PowerShell from Git Bash with $ variables causes credential GUI popups because Bash strips the $ before PowerShell sees it. Always use -NonInteractive or write to a .ps1 file first.", "context": "Git Bash + PowerShell integration", "confidence": 0.90, "session_source": "session-abc123"}
```

## Rules

1. **Be specific** - Include actual commands, file paths, error messages, and code. Vague learnings are useless.

2. **Prefer solutions over problems** - If there was a problem AND a solution, extract the solution. Only extract the problem as a FAILURE if no solution was found.

3. **Include context** - What project, what technology, what situation triggered this learning?

4. **Confidence scoring**:
   - 0.95+ = Explicitly confirmed working in the transcript
   - 0.85-0.94 = Strong evidence it works, minor uncertainty
   - 0.70-0.84 = Reasonable inference from context
   - Below 0.70 = Don't include it

5. **Deduplicate** - If the same learning appears in multiple sessions, extract it once with the most detailed version.

6. **Skip noise** - Don't extract:
   - Generic programming knowledge (Claude already knows this)
   - Incomplete thoughts or abandoned approaches
   - Context that only makes sense within that specific session
   - Temporary debugging steps

7. **Focus on user-specific knowledge** - Learnings about the user's infrastructure, preferences, file paths, and workflows are more valuable than generic best practices.

## Execution Plan

1. List all .md files in ~/converted-transcripts/
2. Calculate total batches (files ÷ 5, round up)
3. For each batch, dispatch 5 sub-agents in parallel using the Task tool
4. Each sub-agent outputs its learnings as JSONL to stdout
5. Collect all sub-agent outputs
6. Deduplicate learnings that appear across multiple sessions (keep the most detailed version)
7. Write final consolidated output to ~/extracted-learnings.jsonl
8. Report: total files processed, total learnings extracted, any errors

Begin by listing the transcript directory and planning your batches.
