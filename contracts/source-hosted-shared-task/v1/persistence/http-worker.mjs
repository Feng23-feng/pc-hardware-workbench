import {
  startIsolatedHttpServer,
} from "./http-server.mjs";

const dbPath = String(process.env.SQ_DB_PATH ?? "");
if (!dbPath) {
  process.stderr.write("SQ_DB_PATH is required\n");
  process.exit(2);
}

const server = await startIsolatedHttpServer({ dbPath });
process.stdout.write(`${JSON.stringify({
  ready: true,
  base_url: server.baseUrl,
  port: server.port,
})}\n`);

async function shutdown() {
  await server.close().catch(() => {});
  process.exit(0);
}

process.once("SIGINT", shutdown);
process.once("SIGTERM", shutdown);
