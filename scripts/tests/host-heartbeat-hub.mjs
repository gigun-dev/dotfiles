// Run with: node scripts/tests/host-heartbeat-hub.mjs --hub-root /path/to/hub
// Only local fixtures cross the real Python HTTP client / hub D1 boundary.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const argv = process.argv.slice(2);
assert.equal(argv.length, 2, "pass --hub-root /path/to/hub");
assert.equal(argv[0], "--hub-root");
const hubRoot = resolve(argv[1]);
const sender = resolve(dirname(fileURLToPath(import.meta.url)), "../host-heartbeat.py");
const requireHub = createRequire(join(hubRoot, "package.json"));
const { Miniflare, Log, LogLevel, convertV4MiniflareOptions } = requireHub("miniflare");
const temporary = await mkdtemp(join(tmpdir(), "dotfiles-heartbeat-hub-"));
const base = Date.UTC(2026, 9, 3);
const tokens = ["local-fixture-mac-token-000000000000", "local-fixture-vm-token-0000000000000",
  "local-fixture-monitor-token-0000000"];
const sources = ["mac", "mini-vm", "uptime-monitor"];
let mf, db, endpoint;
let blockedExternalFetches = 0;

// Async spawn keeps Miniflare's local listener running while Python waits on HTTP.
function run(command, args, options = {}, input = "") {
  return new Promise((resolveResult, reject) => {
    const child = spawn(command, args, { ...options, stdio: ["pipe", "pipe", "pipe"] });
    let stdout = "", stderr = "";
    child.stdout.on("data", chunk => { stdout += chunk; });
    child.stderr.on("data", chunk => { stderr += chunk; });
    child.on("error", reject);
    child.on("close", code => code === 0 ? resolveResult(stdout) : reject(new Error(
      `local fixture process exited ${code}\n${stdout}\n${stderr}`
    )));
    child.stdin.end(input);
  });
}

const python = `
import importlib.util, json, re, sys
spec = importlib.util.spec_from_file_location("sender", sys.argv[1])
sender = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sender)
fixture = json.load(sys.stdin)
payload = fixture.get("payload")
if payload is None:
    payload = sender.observation(fixture["source"], fixture["boot"], fixture["now"])
try:
    sender.send(fixture["endpoint"], fixture["tokenFile"], payload, local_test=True)
except ValueError as error:
    match = re.search(r"HTTP (\\d+)", str(error))
    if not match:
        raise
    print(json.dumps({"httpStatus": int(match[1]), "payload": payload}))
else:
    print(json.dumps({"httpStatus": 202, "payload": payload}))
`;

async function transmit(source, now = base, bootId = "fixture-boot-1", options = {}) {
  const index = options.tokenIndex ?? sources.indexOf(source);
  const fixture = { source, now, boot: { bootId, bootedAt: base - 300000 },
    endpoint, tokenFile: join(temporary, `token-${index}`), ...options };
  return JSON.parse(await run("python3", ["-c", python, sender], {
    // A developer's proxy must never carry fixture credentials away from loopback.
    env: { ...process.env, NO_PROXY: "127.0.0.1", no_proxy: "127.0.0.1" },
  }, JSON.stringify(fixture)));
}
async function stored(source) {
  const row = await db.prepare("SELECT payload, received_at FROM uptime_reports WHERE source=?")
    .bind(source).first();
  return row && { payload: JSON.parse(row.payload), receivedAt: row.received_at };
}

const settings = {
  name: "dotfiles-heartbeat-hub-local", cf: false, modules: true,
  host: "127.0.0.1", port: 0,
  scriptPath: join(temporary, "build", "local-worker.js"),
  // Outside-repository bundles need an explicit module root in Miniflare.
  modulesRoot: join(temporary, "build"),
  compatibilityDate: "2026-09-03", compatibilityFlags: ["nodejs_compat"],
  d1Databases: { H1_DB: "dotfiles-sender-fixture" },
  resourcePersistencePath: join(temporary, "state"),
  telemetry: { enabled: false }, unsafeTriggerHandlers: true,
  queueProducers: { H1_DISPATCH: "dotfiles-sender-fixture-queue" },
  queueConsumers: { "dotfiles-sender-fixture-queue": { maxBatchSize: 10, maxBatchTimeout: 0 } },
  // Block accidental external probes; the local sink never fetches externally.
  outboundService: () => {
    blockedExternalFetches++;
    return new Response("external fetch forbidden", { status: 502 });
  },
  bindings: {
    H1_LOCAL_TEST_MODE: "true", H1_TEST_NOW: String(base), H1_MONITOR_SCHEDULES: "[]",
    H1_SOURCE_CREDENTIALS: JSON.stringify(sources.map((source, i) => ({
      token: tokens[i], ownerId: "fixture-owner", source, destinations: ["local-sink"],
      ...(i === 2 ? { monitorControl: true } : {}),
    }))),
    H1_UPTIME_CONFIG: JSON.stringify({ macSource: "mac", vmSource: "mini-vm",
      notificationSource: "uptime-monitor" }),
    H1_UPTIME_EXTERNAL: "ok",
  },
  log: new Log(LogLevel.ERROR),
};
async function ready() {
  const address = await mf.ready;
  assert.equal(address.hostname, "127.0.0.1");
  endpoint = new URL("/uptime/heartbeat", address).href;
  db = await mf.getD1Database("H1_DB");
}

try {
  // Dry-run bundles into the disposable fixture directory, never hub's owned dist/.
  await run(process.execPath, [join(hubRoot, "node_modules/wrangler/bin/wrangler.js"),
    "deploy", "--dry-run", "--config", join(hubRoot, "wrangler.h1.jsonc"),
    "--outdir", join(temporary, "build")], {
    cwd: hubRoot, env: { ...process.env, WRANGLER_SEND_METRICS: "false", CI: "true" },
  });
  for (let i = 0; i < tokens.length; i++) {
    await writeFile(join(temporary, `token-${i}`), tokens[i], { mode: 0o600 });
  }
  mf = new Miniflare(convertV4MiniflareOptions(settings));
  await ready();
  const migrations = join(hubRoot, "src/notify/migrations");
  for (const name of (await readdir(migrations)).filter(n => n.endsWith(".sql")).sort()) {
    const sql = await readFile(join(migrations, name), "utf8");
    await db.batch(sql.replace(/^\s*--.*$/gm, "").split(";")
      .map(s => s.trim()).filter(Boolean).map(s => db.prepare(s)));
  }
  const mac = await transmit("mac");
  const vm = await transmit("mini-vm");
  for (const result of [mac, vm]) {
    assert.equal(result.httpStatus, 202);
    assert.deepEqual(Object.keys(result.payload).sort(), ["source", "observedAt", "bootId",
      "bootedAt", "lastSuccessAt", "tunnel", "service", "functional"].sort());
    assert.equal(result.payload.functional, "unknown", "no invented functional check");
    assert.deepEqual((await stored(result.payload.source)).payload, result.payload);
    assert.equal((await stored(result.payload.source)).receivedAt, base);
  }
  assert.equal((await transmit("mac", base, "fixture-boot-1", { payload: mac.payload })).httpStatus,
    202, "same Python payload is idempotent");
  assert.equal((await transmit("mac", base, "fixture-boot-1", { tokenIndex: 1 })).httpStatus,
    403, "VM credential cannot impersonate Mac");
  assert.equal((await transmit("mac", base - 1)).httpStatus, 409, "older observation rejected");
  assert.equal((await transmit("mac", base - 120001)).httpStatus, 400, "stale observation rejected");
  assert.equal((await transmit("mac", base, "fixture-boot-conflict")).httpStatus,
    409, "same timestamp with changed boot is a conflict");
  assert.deepEqual((await stored("mac")).payload, mac.payload, "rejections preserve D1 evidence");

  settings.bindings.H1_TEST_NOW = String(base + 60000);
  await mf.setOptions(convertV4MiniflareOptions(settings));
  await ready();
  const reboot = await transmit("mini-vm", base + 60000, "fixture-boot-2", {
    boot: { bootId: "fixture-boot-2", bootedAt: base + 59000 },
  });
  assert.equal(reboot.httpStatus, 202);
  assert.deepEqual((await stored("mini-vm")).payload, reboot.payload);
  assert.equal((await stored("mini-vm")).receivedAt, base + 60000);
  await mf.dispatchFetch("http://127.0.0.1/cdn-cgi/local/scheduled?cron=*+*+*+*+*");
  const scan = JSON.parse((await db.prepare("SELECT payload FROM uptime_head WHERE singleton=1").first()).payload);
  assert.equal(scan.mac.bootId, "fixture-boot-1");
  assert.equal(scan.vm.bootId, "fixture-boot-2");
  assert.equal(scan.vm.bootedAt, base + 59000);

  await mf.dispose();
  mf = new Miniflare(convertV4MiniflareOptions(settings));
  await ready();
  assert.deepEqual((await stored("mini-vm")).payload, reboot.payload, "receiver restart keeps D1 boot evidence");
  assert.equal(blockedExternalFetches, 0, "no external fetch attempted");
  console.log("Sender/hub integration PASS: Python HTTP, distinct credentials, eight-field D1 evidence, duplicate 202, source 403, old 409, stale 400, boot conflict/change, scan and restart persistence");
} finally {
  await mf?.dispose();
  await rm(temporary, { recursive: true, force: true });
}
