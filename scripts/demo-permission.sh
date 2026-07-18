#!/usr/bin/env bash
# Create a live permission request and wait (up to 120s) for a decision made in the app.
# Usage: demo-permission.sh [bash|plan]
set -u

KIND="${1:-bash}"
SERVER="${NOTCH_SERVER:-http://localhost:4519}"
TOKEN="${NOTCH_TOKEN:-dev-token}"
AUTH=(-H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json")

if [ "$KIND" = "plan" ]; then
  BODY='{"machine":"vm-beta","agent":"claude-code","event":{"session_id":"s-b1","hook_event_name":"PreToolUse","cwd":"/srv/etl-pipeline","tool_name":"ExitPlanMode","tool_input":{"plan":"## Fix flaky ETL test\n\n1. Pin the fixture clock to a fixed date\n2. Retry the S3 upload with backoff\n3. Add a regression test for the race"}}}'
else
  BODY='{"machine":"vm-alpha","agent":"claude-code","event":{"session_id":"s-a1","hook_event_name":"PreToolUse","cwd":"/home/tam/api-server","tool_name":"Bash","tool_input":{"command":"git push origin main"}}}'
fi

ID=$(curl -s "${AUTH[@]}" -d "$BODY" "$SERVER/api/permissions" | jq -r .id)
echo "created permission $ID ($KIND) — waiting up to 120s for a decision from the app..."
curl -s -H "Authorization: Bearer $TOKEN" "$SERVER/api/permissions/$ID/decision?wait=120" | jq -c .
