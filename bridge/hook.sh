#!/bin/bash
# Forwards Claude Code hook events to the mascot bridge.
#
# GOLDEN RULE: this runs on the critical path of every tool call. It must never
# delay or block Claude. If the bridge is down it fails in ~200ms and moves on
# in silence — no retries, nothing on stderr.

INPUT=$(cat 2>/dev/null)

curl -s -X POST \
  -H 'Content-Type: application/json' \
  -d "$INPUT" \
  --connect-timeout 0.2 \
  --max-time 0.6 \
  http://127.0.0.1:4666/hook >/dev/null 2>&1

# Always 0: a hook that returns an error can interfere with the session.
exit 0
