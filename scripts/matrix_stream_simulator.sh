#!/bin/bash
# Matrix Streaming Simulator
# Sends streaming messages from @jarvisbot to the AI Test Room
# simulating real-time AI streaming via message edits.
#
# Usage: ./scripts/matrix_stream_simulator.sh [scenario]
# Scenarios: simple, tools, multi
#
# The script sends an initial message, then repeatedly edits it
# with updated text and org.mellonchat.ai_stream metadata.

set -e

HOMESERVER="http://localhost:6167"
TOKEN="FcGFIJoMcgpNPxd2HKJypTAqfyPcdYAP"
ROOM_ID="%21mIC5L4LazQVDvHt-slkLajaU8A7BIaf2pa_B9d_BGhI"
SCENARIO="${1:-simple}"

# Counter for unique transaction IDs
TXN_COUNTER=0

next_txn() {
  TXN_COUNTER=$((TXN_COUNTER + 1))
  echo "sim_$(date +%s)_${TXN_COUNTER}"
}

# Send initial message, returns event_id
send_message() {
  local body="$1"
  local ai_stream="$2"
  local txn
  txn=$(next_txn)

  local content
  content=$(SEND_BODY="$body" SEND_AI_STREAM="$ai_stream" python3 << 'PYEOF'
import json, os, re

body = os.environ.get('SEND_BODY', '')
ai_stream_json = os.environ.get('SEND_AI_STREAM', '')

# Convert simple markdown bold to HTML
formatted = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', body)

c = {'msgtype': 'm.text', 'body': body}
if formatted != body:
    c['format'] = 'org.matrix.custom.html'
    c['formatted_body'] = formatted

if ai_stream_json:
    c['org.mellonchat.ai_stream'] = json.loads(ai_stream_json)

print(json.dumps(c))
PYEOF
)

  local result
  result=$(curl -s -X PUT \
    "${HOMESERVER}/_matrix/client/v3/rooms/${ROOM_ID}/send/m.room.message/${txn}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$content")

  echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['event_id'])"
}

# Edit a message (m.replace)
edit_message() {
  local event_id="$1"
  local body="$2"
  local ai_stream="$3"
  local txn
  txn=$(next_txn)

  local content
  content=$(EDIT_BODY="$body" EDIT_EVENT_ID="$event_id" EDIT_AI_STREAM="$ai_stream" python3 << 'PYEOF'
import json, os, re

body = os.environ.get('EDIT_BODY', '')
event_id = os.environ.get('EDIT_EVENT_ID', '')
ai_stream_json = os.environ.get('EDIT_AI_STREAM', '')

# Convert simple markdown bold to HTML
formatted = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', body)

new_content = {
    'msgtype': 'm.text',
    'body': body,
}
if formatted != body:
    new_content['format'] = 'org.matrix.custom.html'
    new_content['formatted_body'] = formatted

c = {
    'msgtype': 'm.text',
    'body': '* ' + body,
    'm.new_content': new_content,
    'm.relates_to': {
        'rel_type': 'm.replace',
        'event_id': event_id
    }
}

if ai_stream_json:
    ai_data = json.loads(ai_stream_json)
    c['org.mellonchat.ai_stream'] = ai_data
    c['m.new_content']['org.mellonchat.ai_stream'] = ai_data

print(json.dumps(c))
PYEOF
)

  curl -s -X PUT \
    "${HOMESERVER}/_matrix/client/v3/rooms/${ROOM_ID}/send/m.room.message/${txn}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$content" > /dev/null
}

# === SCENARIOS ===

run_simple() {
  echo "=== Simple Streaming Scenario ==="

  # Send initial message with streaming status
  echo "Sending initial message..."
  local ai_stream='{"status":"streaming"}'
  local event_id
  event_id=$(send_message "..." "$ai_stream")
  echo "Event ID: $event_id"
  sleep 0.3

  # Stream text word by word
  local full_text="Hello! I'm Jarvis, your AI assistant. I can help you with coding, research, and much more. Let me know what you'd like to work on today."
  local accumulated=""

  for word in $full_text; do
    if [ -z "$accumulated" ]; then
      accumulated="$word"
    else
      accumulated="$accumulated $word"
    fi

    edit_message "$event_id" "$accumulated" '{"status":"streaming"}'

    # Random delay between 50-150ms
    sleep 0.$(( RANDOM % 10 + 5 ))
  done

  # Mark complete
  edit_message "$event_id" "$accumulated" '{"status":"complete"}'
  echo "Done!"
}

run_tools() {
  echo "=== Tools Scenario ==="

  # Phase 1: Tool execution - Grep
  echo "Phase 1: Grep tool..."
  local ai_stream='{"status":"tool","tool_name":"Grep","tool_args":{"pattern":"TODO","path":"lib/"},"progress":0}'
  local event_id
  event_id=$(send_message "..." "$ai_stream")
  echo "Event ID: $event_id"

  # Simulate tool progress
  for p in 20 40 60 80 100; do
    local progress_json="{\"status\":\"tool\",\"tool_name\":\"Grep\",\"tool_args\":{\"pattern\":\"TODO\",\"path\":\"lib/\"},\"progress\":$p}"
    edit_message "$event_id" "..." "$progress_json"
    sleep 0.2
  done

  # Tool complete, start streaming response
  echo "Phase 2: Streaming response..."
  local completed_tools='[{"name":"Grep","args":{"pattern":"TODO","path":"lib/"},"output":"lib/main.dart:42: // TODO: Add error handling\nlib/utils.dart:15: // TODO: Optimize this","collapsed":true}]'

  local response_text="Found 2 TODO comments in your codebase. The first one in **main.dart** at line 42 needs error handling added. The second in **utils.dart** at line 15 mentions optimization that should be addressed."
  local accumulated=""

  for word in $response_text; do
    if [ -z "$accumulated" ]; then
      accumulated="$word"
    else
      accumulated="$accumulated $word"
    fi

    local stream_json="{\"status\":\"streaming\",\"completed_tools\":$completed_tools}"
    edit_message "$event_id" "$accumulated" "$stream_json"
    sleep 0.$(( RANDOM % 10 + 5 ))
  done

  # Mark complete
  local final_json="{\"status\":\"complete\",\"completed_tools\":$completed_tools}"
  edit_message "$event_id" "$accumulated" "$final_json"
  echo "Done!"
}

run_multi() {
  echo "=== Multi-Tool Scenario ==="

  # Phase 1: Initial streaming text
  echo "Phase 1: Initial response..."
  local ai_stream='{"status":"streaming"}'
  local event_id
  event_id=$(send_message "..." "$ai_stream")
  echo "Event ID: $event_id"
  sleep 0.3

  local intro_text="Let me check your project setup. I'll look at a few things."
  local accumulated=""
  for word in $intro_text; do
    if [ -z "$accumulated" ]; then
      accumulated="$word"
    else
      accumulated="$accumulated $word"
    fi
    edit_message "$event_id" "$accumulated" '{"status":"streaming"}'
    sleep 0.$(( RANDOM % 8 + 4 ))
  done
  sleep 0.3

  # Phase 2: Tool 1 - Bash
  echo "Phase 2: Bash tool..."
  local tool1_json='{"status":"tool","tool_name":"Bash","tool_args":{"command":"flutter --version"},"progress":0}'
  edit_message "$event_id" "$accumulated" "$tool1_json"

  for p in 25 50 75 100; do
    tool1_json="{\"status\":\"tool\",\"tool_name\":\"Bash\",\"tool_args\":{\"command\":\"flutter --version\"},\"progress\":$p}"
    edit_message "$event_id" "$accumulated" "$tool1_json"
    sleep 0.15
  done

  local ct1='[{"name":"Bash","args":{"command":"flutter --version"},"output":"Flutter 3.38.9 • channel stable\nDart 3.10.8","collapsed":true}]'
  sleep 0.2

  # Phase 3: Tool 2 - Read
  echo "Phase 3: Read tool..."
  local tool2_json="{\"status\":\"tool\",\"tool_name\":\"Read\",\"tool_args\":{\"path\":\"pubspec.yaml\"},\"progress\":0,\"completed_tools\":$ct1}"
  edit_message "$event_id" "$accumulated" "$tool2_json"

  for p in 33 66 100; do
    tool2_json="{\"status\":\"tool\",\"tool_name\":\"Read\",\"tool_args\":{\"path\":\"pubspec.yaml\"},\"progress\":$p,\"completed_tools\":$ct1}"
    edit_message "$event_id" "$accumulated" "$tool2_json"
    sleep 0.15
  done

  local ct2='[{"name":"Bash","args":{"command":"flutter --version"},"output":"Flutter 3.38.9 • channel stable\nDart 3.10.8","collapsed":true},{"name":"Read","args":{"path":"pubspec.yaml"},"output":"name: mellon_chat\nversion: 1.0.0\ndependencies:\n  flutter:\n    sdk: flutter\n  matrix: ^0.25.0","collapsed":true}]'
  sleep 0.2

  # Phase 4: Tool 3 - Bash pub get
  echo "Phase 4: Bash pub get..."
  local tool3_json="{\"status\":\"tool\",\"tool_name\":\"Bash\",\"tool_args\":{\"command\":\"flutter pub get\"},\"progress\":0,\"completed_tools\":$ct2}"
  edit_message "$event_id" "$accumulated" "$tool3_json"

  for p in 20 40 60 80 100; do
    tool3_json="{\"status\":\"tool\",\"tool_name\":\"Bash\",\"tool_args\":{\"command\":\"flutter pub get\"},\"progress\":$p,\"completed_tools\":$ct2}"
    edit_message "$event_id" "$accumulated" "$tool3_json"
    sleep 0.15
  done

  local ct3='[{"name":"Bash","args":{"command":"flutter --version"},"output":"Flutter 3.38.9 • channel stable\nDart 3.10.8","collapsed":true},{"name":"Read","args":{"path":"pubspec.yaml"},"output":"name: mellon_chat\nversion: 1.0.0\ndependencies:\n  flutter:\n    sdk: flutter\n  matrix: ^0.25.0","collapsed":true},{"name":"Bash","args":{"command":"flutter pub get"},"output":"Resolving dependencies...\nGot dependencies!","collapsed":true}]'
  sleep 0.3

  # Phase 5: Final streaming response
  echo "Phase 5: Final response..."
  local final_text="Your project looks great! You're running **Flutter 3.38.9** with Dart 3.10.8. All dependencies resolved successfully. The project is ready for development."
  accumulated=""

  for word in $final_text; do
    if [ -z "$accumulated" ]; then
      accumulated="$word"
    else
      accumulated="$accumulated $word"
    fi
    local stream_json="{\"status\":\"streaming\",\"completed_tools\":$ct3}"
    edit_message "$event_id" "$accumulated" "$stream_json"
    sleep 0.$(( RANDOM % 8 + 4 ))
  done

  # Mark complete
  local final_json="{\"status\":\"complete\",\"completed_tools\":$ct3}"
  edit_message "$event_id" "$accumulated" "$final_json"
  echo "Done!"
}

run_todo() {
  echo "=== Todo List Scenario ==="

  # Phase 1: Initial streaming
  echo "Phase 1: Initial response..."
  local ai_stream='{"status":"streaming"}'
  local event_id
  event_id=$(send_message "..." "$ai_stream")
  echo "Event ID: $event_id"
  sleep 0.3

  local intro_text="Let me plan the implementation for adding dark mode support."
  local accumulated=""
  for word in $intro_text; do
    if [ -z "$accumulated" ]; then
      accumulated="$word"
    else
      accumulated="$accumulated $word"
    fi
    edit_message "$event_id" "$accumulated" '{"status":"streaming"}'
    sleep 0.$(( RANDOM % 8 + 4 ))
  done
  sleep 0.3

  # Phase 2: TodoWrite tool call - initial todos
  echo "Phase 2: TodoWrite - setting up tasks..."
  local todos_initial='[{"content":"Create ThemeProvider with dark/light mode toggle","status":"in_progress"},{"content":"Update AppBar and navigation colors","status":"pending"},{"content":"Update card and surface colors","status":"pending"},{"content":"Add theme preference persistence","status":"pending"},{"content":"Run tests to verify theme switching","status":"pending"}]'
  local todo_meta="{\"status\":\"tool\",\"tool_name\":\"TodoWrite\",\"todos\":$todos_initial}"
  edit_message "$event_id" "$accumulated" "$todo_meta"
  sleep 1.5

  # Phase 3: First task done, second in progress
  echo "Phase 3: Task 1 complete, starting task 2..."
  local todos_p2='[{"content":"Create ThemeProvider with dark/light mode toggle","status":"completed"},{"content":"Update AppBar and navigation colors","status":"in_progress"},{"content":"Update card and surface colors","status":"pending"},{"content":"Add theme preference persistence","status":"pending"},{"content":"Run tests to verify theme switching","status":"pending"}]'
  local ct1='[{"name":"Write","args":{"path":"lib/theme_provider.dart"},"output":"Created ThemeProvider with ThemeMode toggle","collapsed":true}]'
  local todo_meta2="{\"status\":\"streaming\",\"todos\":$todos_p2,\"completed_tools\":$ct1}"
  local text2="Created the ThemeProvider. Now updating the navigation colors."
  edit_message "$event_id" "$text2" "$todo_meta2"
  sleep 1.5

  # Phase 4: Two tasks done
  echo "Phase 4: Task 2 complete..."
  local todos_p3='[{"content":"Create ThemeProvider with dark/light mode toggle","status":"completed"},{"content":"Update AppBar and navigation colors","status":"completed"},{"content":"Update card and surface colors","status":"in_progress"},{"content":"Add theme preference persistence","status":"pending"},{"content":"Run tests to verify theme switching","status":"pending"}]'
  local ct2='[{"name":"Write","args":{"path":"lib/theme_provider.dart"},"output":"Created ThemeProvider","collapsed":true},{"name":"Edit","args":{"file_path":"lib/main.dart"},"output":"Updated AppBar colors","collapsed":true}]'
  local todo_meta3="{\"status\":\"streaming\",\"todos\":$todos_p3,\"completed_tools\":$ct2}"
  local text3="Navigation colors updated. Now working on card and surface colors."
  edit_message "$event_id" "$text3" "$todo_meta3"
  sleep 1.5

  # Phase 5: Final - all done
  echo "Phase 5: All tasks complete..."
  local todos_final='[{"content":"Create ThemeProvider with dark/light mode toggle","status":"completed"},{"content":"Update AppBar and navigation colors","status":"completed"},{"content":"Update card and surface colors","status":"completed"},{"content":"Add theme preference persistence","status":"completed"},{"content":"Run tests to verify theme switching","status":"completed"}]'
  local ct_final='[{"name":"Write","args":{"path":"lib/theme_provider.dart"},"output":"Created ThemeProvider","collapsed":true},{"name":"Edit","args":{"file_path":"lib/main.dart"},"output":"Updated AppBar colors","collapsed":true},{"name":"Edit","args":{"file_path":"lib/widgets/card.dart"},"output":"Updated surface colors","collapsed":true},{"name":"Edit","args":{"file_path":"lib/storage.dart"},"output":"Added SharedPreferences for theme","collapsed":true},{"name":"Bash","args":{"command":"flutter test"},"output":"All 42 tests passed!","collapsed":true}]'
  local todo_final="{\"status\":\"complete\",\"todos\":$todos_final,\"completed_tools\":$ct_final}"
  local text_final="Dark mode support is complete! All 5 tasks finished successfully. The ThemeProvider manages dark/light mode toggling, colors are updated across all components, and preferences are persisted with SharedPreferences."
  edit_message "$event_id" "$text_final" "$todo_final"
  echo "Done!"
}

# Run selected scenario
case "$SCENARIO" in
  simple)
    run_simple
    ;;
  tools)
    run_tools
    ;;
  multi)
    run_multi
    ;;
  todo)
    run_todo
    ;;
  *)
    echo "Unknown scenario: $SCENARIO"
    echo "Available: simple, tools, multi, todo"
    exit 1
    ;;
esac
