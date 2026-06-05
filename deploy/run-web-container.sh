#!/bin/sh
set -eu

export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

container_name="mellon-chat-web"
script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repo_dir="$(CDPATH= cd -- "$script_dir/.." && pwd)"
web_dir="$repo_dir/build/web"
nginx_conf="$repo_dir/deploy/nginx.conf"

while ! docker info >/dev/null 2>&1; do
  sleep 5
done

if docker ps -a --format '{{.Names}}' | grep -qx "$container_name"; then
  docker start "$container_name" >/dev/null
else
  docker run -d \
    --name "$container_name" \
    --restart unless-stopped \
    -p 127.0.0.1:8081:80 \
    -v "$web_dir:/usr/share/nginx/html:ro" \
    -v "$nginx_conf:/etc/nginx/conf.d/default.conf:ro" \
    nginx:alpine >/dev/null
fi

docker logs -f "$container_name"
