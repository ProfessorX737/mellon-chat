#!/bin/sh
set -eu

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.cargo/bin:/usr/bin:/bin:/usr/sbin:/sbin"

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repo_dir="$(CDPATH= cd -- "$script_dir/.." && pwd)"
container_name="mellon-chat-web"
network_name="mellon-chat-net"
dev_log_container_name="mellon-chat-dev-log"
port="8081"
dev_log_port="8092"

cd "$repo_dir"

mkdir -p /tmp/mellon-chat
if ! docker network inspect "$network_name" >/dev/null 2>&1; then
  docker network create "$network_name" >/dev/null
fi
if docker ps -a --format '{{.Names}}' | grep -qx "$dev_log_container_name"; then
  docker rm -f "$dev_log_container_name" >/dev/null
fi
docker run -d \
  --name "$dev_log_container_name" \
  --restart unless-stopped \
  --network "$network_name" \
  -p "127.0.0.1:$dev_log_port:$dev_log_port" \
  -e MELLON_DEV_LOG_HOST=0.0.0.0 \
  -e MELLON_DEV_LOG_PORT="$dev_log_port" \
  -e MELLON_DEV_LOG_PATH=/tmp/mellon-chat/subchat-routing.jsonl \
  -v "$repo_dir/deploy/dev-log-server.mjs:/app/dev-log-server.mjs:ro" \
  -v "/tmp/mellon-chat:/tmp/mellon-chat" \
  node:22-alpine node /app/dev-log-server.mjs >/dev/null

if [ "${PREPARE_WEB:-0}" = "1" ]; then
  ./scripts/prepare-web.sh
fi

build_id="$(date -u +%Y%m%d%H%M%S)"
build_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
app_version="$(sed -n 's/^version:[[:space:]]*//p' "$repo_dir/pubspec.yaml" | head -n 1)"
git_sha="$(git rev-parse --short=12 HEAD 2>/dev/null || printf unknown)"
git_dirty=false
if [ -n "$(git status --porcelain 2>/dev/null || true)" ]; then
  git_dirty=true
fi

"$repo_dir/.fvm/flutter_sdk/bin/flutter" build web \
  --dart-define=FLUTTER_WEB_CANVASKIT_URL=canvaskit/ \
  --dart-define=MELLON_APP_VERSION="$app_version" \
  --dart-define=MELLON_BUILD_ID="$build_id" \
  --dart-define=MELLON_BUILD_TIME="$build_time" \
  --dart-define=MELLON_GIT_SHA="$git_sha" \
  --dart-define=MELLON_GIT_DIRTY="$git_dirty" \
  --release \
  --source-maps

/usr/bin/perl -0pi -e "s/\"mainJsPath\":\"main\\.dart\\.js\"/\"mainJsPath\":\"main.dart.js?v=$build_id\"/g" \
  "$repo_dir/build/web/index.html" \
  "$repo_dir/build/web/flutter_bootstrap.js"
/usr/bin/perl -0pi -e "s/createScriptURL\\(s\\+r\\+b\\)/createScriptURL(s+r+(b===\"\"?\"?v=$build_id\":\"?v=$build_id&\"+b.substring(1)))/g; s/createScriptURL\\(c\\+b\\+d\\)/createScriptURL(c+b+(d===\"\"?\"?v=$build_id\":\"?v=$build_id&\"+d.substring(1)))/g" \
  "$repo_dir/build/web/main.dart.js"
/usr/bin/perl -0pi -e "s/__MELLON_APP_VERSION__/$app_version/g; s/__MELLON_BUILD_ID__/$build_id/g; s/__MELLON_BUILD_TIME__/$build_time/g; s/__MELLON_GIT_SHA__/$git_sha/g; s/__MELLON_GIT_DIRTY__/$git_dirty/g" \
  "$repo_dir/build/web/index.html"
cat > "$repo_dir/build/web/mellon-build.json" <<JSON
{
  "app_version": "$app_version",
  "build_id": "$build_id",
  "build_time": "$build_time",
  "git_sha": "$git_sha",
  "git_dirty": $git_dirty,
  "main_js_path": "main.dart.js?v=$build_id"
}
JSON

if docker ps -a --format '{{.Names}}' | grep -qx "$container_name"; then
  docker rm -f "$container_name" >/dev/null
fi
docker run -d \
  --name "$container_name" \
  --restart unless-stopped \
  --network "$network_name" \
  -p "127.0.0.1:$port:80" \
  -v "$repo_dir/deploy/nginx.conf:/etc/nginx/conf.d/default.conf:ro" \
  nginx:alpine >/dev/null
docker exec "$container_name" sh -lc 'rm -rf /usr/share/nginx/html/*'
docker cp "$repo_dir/build/web/." "$container_name:/usr/share/nginx/html/"
docker exec "$container_name" nginx -s reload >/dev/null 2>&1 || true

curl -fsSI "http://127.0.0.1:$port/" >/dev/null
curl -fsS "http://127.0.0.1:$port/config.json" | grep -q "https://matrix.mellon.chat"

echo "Mellon Chat release build is live locally on http://127.0.0.1:$port and through the existing tunnel."
