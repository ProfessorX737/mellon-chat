import { createServer } from "node:http";
import { mkdir, readFile, appendFile } from "node:fs/promises";
import { dirname } from "node:path";

const port = Number(process.env.MELLON_DEV_LOG_PORT || "8092");
const host = process.env.MELLON_DEV_LOG_HOST || "127.0.0.1";
const logPath =
  process.env.MELLON_DEV_LOG_PATH || "/tmp/mellon-chat/subchat-routing.jsonl";
const maxBodyBytes = 64 * 1024;
const maxEntries = 300;

const escapeHtml = (value) =>
  String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");

async function readRecentEntries() {
  try {
    const raw = await readFile(logPath, "utf8");
    return raw
      .split("\n")
      .filter(Boolean)
      .slice(-maxEntries)
      .map((line) => {
        try {
          return JSON.parse(line);
        } catch {
          return { malformed: true, line };
        }
      });
  } catch (error) {
    if (error?.code === "ENOENT") return [];
    throw error;
  }
}

function renderHtml(entries) {
  const rows = entries
    .slice()
    .reverse()
    .map((entry) => {
      const timestamp = entry.server_time || entry.time || "";
      const source = entry.source || "";
      const event = entry.event || "";
      return `<tr>
  <td>${escapeHtml(timestamp)}</td>
  <td>${escapeHtml(source)}</td>
  <td>${escapeHtml(event)}</td>
  <td><pre>${escapeHtml(JSON.stringify(entry, null, 2))}</pre></td>
</tr>`;
    })
    .join("\n");

  return `<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="refresh" content="5">
  <title>Mellon debug logs</title>
  <style>
    body { margin: 0; background: #0c1117; color: #dbe7f3; font: 13px ui-monospace, SFMono-Regular, Menlo, monospace; }
    header { position: sticky; top: 0; padding: 14px 18px; background: #111a24; border-bottom: 1px solid #283442; }
    h1 { margin: 0; font: 600 16px system-ui, sans-serif; }
    p { margin: 6px 0 0; color: #8ea1b3; font: 13px system-ui, sans-serif; }
    table { width: 100%; border-collapse: collapse; }
    td, th { vertical-align: top; padding: 10px 12px; border-bottom: 1px solid #1e2a36; }
    th { text-align: left; color: #9fb2c5; background: #101820; position: sticky; top: 65px; }
    pre { margin: 0; white-space: pre-wrap; color: #d7e5f5; }
    a { color: #7cc7ff; }
  </style>
</head>
<body>
  <header>
    <h1>Mellon debug logs</h1>
    <p>Auto-refreshes every 5 seconds. JSON view: <a href="?format=json">?format=json</a></p>
  </header>
  <table>
    <thead><tr><th>Time</th><th>Source</th><th>Event</th><th>Payload</th></tr></thead>
    <tbody>${rows || '<tr><td colspan="4">No debug logs yet.</td></tr>'}</tbody>
  </table>
</body>
</html>`;
}

async function readRequestBody(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > maxBodyBytes) {
      throw Object.assign(new Error("Request body too large"), { statusCode: 413 });
    }
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString("utf8");
}

async function handlePost(request, response) {
  const body = await readRequestBody(request);
  const parsed = body ? JSON.parse(body) : {};
  const entry = {
    server_time: new Date().toISOString(),
    ...parsed,
  };
  await mkdir(dirname(logPath), { recursive: true });
  await appendFile(logPath, `${JSON.stringify(entry)}\n`, "utf8");
  response.writeHead(204).end();
}

async function handleGet(request, response) {
  const url = new URL(request.url || "/", `http://${request.headers.host || "localhost"}`);
  const entries = await readRecentEntries();
  if (url.searchParams.get("format") === "json") {
    response.writeHead(200, {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
    });
    response.end(JSON.stringify({ logPath, entries }, null, 2));
    return;
  }

  response.writeHead(200, {
    "content-type": "text/html; charset=utf-8",
    "cache-control": "no-store",
  });
  response.end(renderHtml(entries));
}

const server = createServer(async (request, response) => {
  response.setHeader("access-control-allow-origin", "*");
  response.setHeader("access-control-allow-methods", "GET,POST,OPTIONS");
  response.setHeader("access-control-allow-headers", "content-type");

  if (request.method === "OPTIONS") {
    response.writeHead(204).end();
    return;
  }

  try {
    if (request.method === "POST") {
      await handlePost(request, response);
      return;
    }
    if (request.method === "GET" || request.method === "HEAD") {
      await handleGet(request, response);
      return;
    }
    response.writeHead(405).end("Method not allowed");
  } catch (error) {
    const statusCode = error?.statusCode || 500;
    response.writeHead(statusCode, {
      "content-type": "text/plain; charset=utf-8",
      "cache-control": "no-store",
    });
    response.end(String(error?.message || error));
  }
});

server.listen(port, host, () => {
  console.log(`Mellon dev log server listening on http://${host}:${port}`);
  console.log(`Writing debug logs to ${logPath}`);
});
