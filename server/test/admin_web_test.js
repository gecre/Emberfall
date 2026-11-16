/**
 * Admin dashboard tests: the page, the key check, the data routes and the
 * in-process restore.
 *
 * Runs entirely in a throwaway data directory so the real server database is
 * never touched.
 */
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const serverRoot = path.resolve(here, "..");
const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "emberfall-dash-test-"));
const dbPath = path.join(tempDir, "test.sqlite");
const port = 7595;
const KEY = "test-admin-key";

let failures = 0;
let checks = 0;

function check(condition, message, detail = "") {
  checks += 1;
  if (condition) {
    console.log(`PASS: ${message}`);
  } else {
    failures += 1;
    console.log(`FAIL: ${message}${detail ? ` (${detail})` : ""}`);
  }
}

function env(extra = {}) {
  return {
    ...process.env,
    PORT: String(port),
    HOST: "127.0.0.1",
    EMBERFALL_DATA_DIR: tempDir,
    EMBERFALL_DB: dbPath,
    EMBERFALL_BACKUP_DIR: path.join(tempDir, "backups"),
    EMBERFALL_ADMIN_KEY: KEY,
    EMBERFALL_JWT_SECRET: "test-secret-only",
    EMBERFALL_QUIET: "1",
    ...extra,
  };
}

async function api(method, route, body, headers = {}) {
  const response = await fetch(`http://127.0.0.1:${port}${route}`, {
    method,
    headers: {
      ...(body !== undefined ? { "Content-Type": "application/json" } : {}),
      ...headers,
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    json = text;
  }
  return { status: response.status, json, text };
}

const admin = (method, route, body) =>
  api(method, `/admin${route}`, body, { "X-Admin-Key": KEY });

let server = null;
let serverLog = "";

async function startServer() {
  server = spawn(
    process.execPath,
    [path.join(serverRoot, "src", "index.js")],
    { env: env(), stdio: ["ignore", "pipe", "pipe"] },
  );
  server.stdout.on("data", (chunk) => (serverLog += chunk));
  server.stderr.on("data", (chunk) => (serverLog += chunk));
  for (let attempt = 0; attempt < 100; attempt += 1) {
    try {
      const res = await fetch(`http://127.0.0.1:${port}/api/health`);
      if (res.ok) return;
    } catch {
      // not up yet
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`server did not start\n${serverLog}`);
}

async function stopServer() {
  if (!server) return;
  const child = server;
  server = null;
  await new Promise((resolve) => {
    child.once("exit", resolve);
    child.kill();
  });
}

try {
  await startServer();

  const suffix = Date.now().toString(36);
  const alice = `alice_${suffix}`.slice(0, 20);

  // --- the page -----------------------------------------------------------
  const page = await api("GET", "/admin");
  check(page.status === 200, "the dashboard page is served", `status ${page.status}`);
  check(page.text.includes(KEY), "the page carries the admin key");
  check(
    !("access-control-allow-origin" in (page.headers ?? {})),
    "the page sends no CORS header",
  );

  // The page must not have two elements with the same id: a duplicate id
  // silently breaks getElementById lookups.
  const ids = [...page.text.matchAll(/id="([^"]+)"/g)].map((m) => m[1]);
  const duplicates = ids.filter((id, index) => ids.indexOf(id) !== index);
  check(
    duplicates.length === 0,
    "the page has no duplicate element ids",
    duplicates.join(", "),
  );

  // --- the key check ------------------------------------------------------
  const noKey = await api("GET", "/admin/api/overview");
  check(noKey.status === 401, "a data route without the key is refused", `status ${noKey.status}`);

  const badKey = await api("GET", "/admin/api/overview", undefined, { "X-Admin-Key": "wrong" });
  check(badKey.status === 401, "a data route with the wrong key is refused", `status ${badKey.status}`);

  // --- overview -----------------------------------------------------------
  const overview = await admin("GET", "/api/overview");
  check(overview.status === 200, "overview succeeds", overview.text);
  check(overview.json.items === 728, "overview counts the item catalog", JSON.stringify(overview.json));
  check(overview.json.journal_mode === "wal", "overview reports the journal mode", JSON.stringify(overview.json));

  // --- data ---------------------------------------------------------------
  const reg = await api("POST", "/api/register", {
    username: alice,
    password: "password123",
  });
  check(reg.status === 201, "register an account", `status ${reg.status}`);

  const accounts = await admin("GET", "/api/accounts");
  check(accounts.status === 200, "accounts succeeds", accounts.text);
  check(
    accounts.json.accounts.some((a) => a.username === alice),
    "accounts lists the new account",
  );

  const characters = await admin("GET", "/api/characters");
  check(characters.status === 200, "characters succeeds", characters.text);

  const items = await admin("GET", "/api/items?q=sword");
  check(items.status === 200, "items succeeds", items.text);
  check(items.json.items.length > 0, "the item search finds something", JSON.stringify(items.json).slice(0, 120));

  // --- ban / unban --------------------------------------------------------
  const ban = await admin("POST", "/api/accounts/1/ban", { reason: "dashboard test" });
  check(ban.status === 200, "ban succeeds", ban.text);
  check(ban.json.account.banned === 1, "the account is marked banned", JSON.stringify(ban.json));

  const unban = await admin("POST", "/api/accounts/1/unban");
  check(unban.status === 200, "unban succeeds", unban.text);
  check(unban.json.account.banned === 0, "the ban is lifted", JSON.stringify(unban.json));

  const mute = await admin("POST", "/api/accounts/1/mute", { reason: "dashboard test" });
  check(mute.json.account.muted === 1, "the account is marked muted", JSON.stringify(mute.json));

  const unmute = await admin("POST", "/api/accounts/1/unmute");
  check(unmute.json.account.muted === 0, "the mute is lifted", JSON.stringify(unmute.json));

  // --- password -----------------------------------------------------------
  const password = await admin("POST", "/api/accounts/1/password", { password: "newdashboardpass" });
  check(password.status === 200, "setpassword succeeds", password.text);

  const login = await api("POST", "/api/login", {
    username: alice,
    password: "newdashboardpass",
  });
  check(login.status === 200, "the new password works", `status ${login.status}`);

  const shortPassword = await admin("POST", "/api/accounts/1/password", { password: "abc" });
  check(shortPassword.status === 400, "a short password is refused", shortPassword.text);

  // --- query --------------------------------------------------------------
  const query = await admin("POST", "/api/query", { sql: "SELECT id, username FROM accounts" });
  check(query.status === 200, "query succeeds", query.text);
  check(query.json.rows.length === 1, "query returns the account", JSON.stringify(query.json));

  const write = await admin("POST", "/api/query", { sql: "DELETE FROM accounts" });
  check(write.status === 400, "query refuses a write", write.text);

  const broken = await admin("POST", "/api/query", { sql: "SELECT * FROM nope" });
  check(broken.status === 400, "query reports a bad statement", broken.text);

  // --- backups ------------------------------------------------------------
  const backup = await admin("POST", "/api/backups");
  check(backup.status === 200, "a snapshot can be taken from the dashboard", backup.text);
  check(fs.existsSync(backup.json.file), "the snapshot file exists", backup.json.file);

  const backups = await admin("GET", "/api/backups");
  check(backups.status === 200, "the snapshot list succeeds", backups.text);
  check(backups.json.backups.length > 0, "the snapshot list is not empty");

  const verify = await admin("GET", `/api/backups/verify?file=${encodeURIComponent(backup.json.file)}`);
  check(verify.status === 200, "a snapshot can be verified", verify.text);

  // --- restore while the server keeps running ------------------------------
  // Change something, then restore the snapshot taken before the change.
  const before = await admin("POST", "/api/accounts/1/ban", { reason: "after the snapshot" });
  check(before.json.account.banned === 1, "the account is banned again");

  const restore = await admin("POST", "/api/backups/restore", { file: backup.json.file });
  check(restore.status === 200, "the dashboard can restore a snapshot", restore.text);
  check(restore.json.accounts === 1, "the restore reports the account count", JSON.stringify(restore.json));
  check(fs.existsSync(restore.json.safety), "the restore kept a pre-restore snapshot", restore.json.safety);

  const afterRestore = await admin("GET", "/api/accounts");
  const restored = afterRestore.json.accounts.find((a) => a.username === alice);
  check(
    restored && restored.banned === 0,
    "the restore rolled the account back",
    JSON.stringify(restored),
  );

  // The server has to keep working after the database was swapped underneath.
  const health = await api("GET", "/api/health");
  check(health.status === 200, "the API still works after the restore", `status ${health.status}`);
  check(health.json.items === 728, "the item catalog was reloaded", JSON.stringify(health.json));

  const relogin = await api("POST", "/api/login", {
    username: alice,
    password: "newdashboardpass",
  });
  check(relogin.status === 200, "an account can log in after the restore", `status ${relogin.status}`);

  // --- delete -------------------------------------------------------------
  const del = await admin("DELETE", "/api/accounts/1");
  check(del.status === 200, "delete succeeds", del.text);
  check(del.json.deleted === alice, "the right account was deleted", JSON.stringify(del.json));

  const gone = await admin("GET", "/api/accounts");
  check(
    !gone.json.accounts.some((a) => a.username === alice),
    "the account is gone",
    JSON.stringify(gone.json),
  );

  const missing = await admin("DELETE", "/api/accounts/999");
  check(missing.status === 404, "deleting an unknown account is a 404", missing.text);
} catch (error) {
  failures += 1;
  console.log(`FAIL: unexpected error - ${error.message}`);
} finally {
  await stopServer();
  fs.rmSync(tempDir, { recursive: true, force: true });
}

console.log(`\n${checks - failures}/${checks} checks passed.`);
process.exit(failures > 0 ? 1 : 0);
