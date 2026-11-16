/**
 * Backup and restore tests.
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
const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "emberfall-backup-test-"));
const dbPath = path.join(tempDir, "test.sqlite");
const backupDir = path.join(tempDir, "backups");
const port = 7597;

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

/** Environment that points the server and the CLI at the throwaway database. */
function env(extra = {}) {
  return {
    ...process.env,
    PORT: String(port),
    HOST: "127.0.0.1",
    EMBERFALL_DATA_DIR: tempDir,
    EMBERFALL_DB: dbPath,
    EMBERFALL_BACKUP_DIR: backupDir,
    EMBERFALL_JWT_SECRET: "test-secret-only",
    EMBERFALL_QUIET: "1",
    ...extra,
  };
}

/** Runs the admin CLI and captures its output. */
function cli(args) {
  return new Promise((resolve) => {
    const child = spawn(
      process.execPath,
      [path.join(serverRoot, "src", "admin.js"), ...args],
      { env: env(), stdio: ["ignore", "pipe", "pipe"] },
    );
    let output = "";
    child.stdout.on("data", (chunk) => (output += chunk));
    child.stderr.on("data", (chunk) => (output += chunk));
    child.on("close", (code) => resolve({ code, output }));
  });
}

async function api(method, route, body, token) {
  const headers = {};
  if (body !== undefined) headers["Content-Type"] = "application/json";
  if (token) headers.Authorization = `Bearer ${token}`;
  const response = await fetch(`http://127.0.0.1:${port}/api${route}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    json = text;
  }
  return { status: response.status, json };
}

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

function snapshots() {
  if (!fs.existsSync(backupDir)) return [];
  return fs.readdirSync(backupDir).filter((n) => n.endsWith(".sqlite"));
}

/** A complete, valid save payload. */
function makeSave(name, playerClass, level, gold) {
  return {
    version: 1,
    player_name: name,
    player_class: playerClass,
    level,
    xp: 0,
    gold,
    current_hp: 100,
    current_mp: 50,
    current_stage: 1,
    unlocked_stage: 1,
    bonus_hp: 0,
    bonus_mp: 0,
    skill_points: 3,
    special_skill_points: 1,
    camera_zoom: 1.0,
    show_fps: false,
    play_time: 0.0,
    inventory: [],
    equipment: {
      weapon: "",
      helmet: "",
      armor: "",
      legs: "",
      boots: "",
      shield: "",
      accessory: "",
      pet_helmet: "",
    },
    attributes: {
      strength: 1,
      power: 1,
      range: 1,
      magic: 1,
      artillery: 1,
      defense: 1,
      dexterity: 1,
      luck: 1,
    },
    skills: {},
    quests: {},
  };
}

try {
  await startServer();

  // --- seed some data through the API -------------------------------------
  const suffix = Date.now().toString(36);
  const alice = `alice_${suffix}`.slice(0, 20);
  const bob = `bob_${suffix}`.slice(0, 20);

  const regA = await api("POST", "/register", {
    username: alice,
    password: "password123",
  });
  check(regA.status === 201, "register first account", `status ${regA.status}`);

  const regB = await api("POST", "/register", {
    username: bob,
    password: "password123",
  });
  check(regB.status === 201, "register second account", `status ${regB.status}`);

  const heroName = `Hero_${suffix}`.slice(0, 20);
  const create = await api(
    "POST",
    "/characters",
    {
      name: heroName,
      class: "Mage",
      data: makeSave(heroName, "Mage", 7, 1234),
    },
    regA.json.token,
  );
  check(create.status === 201, "create a character", `status ${create.status}`);
  const characterId = create.json?.character?.id;

  // --- backup while the server is running ---------------------------------
  const backup1 = await cli(["backup"]);
  check(backup1.code === 0, "backup command succeeds", backup1.output);
  check(
    backup1.output.includes("accounts: 2") && backup1.output.includes("characters: 1"),
    "backup reports the seeded row counts",
    backup1.output.trim(),
  );
  check(snapshots().length === 1, "one snapshot written", snapshots().join(", "));
  const snapshot1 = path.join(backupDir, snapshots()[0]);
  check(
    fs.existsSync(snapshot1.replace(/\.sqlite$/, ".json")),
    "snapshot has a manifest",
  );

  // --- the snapshot must be self-contained ---------------------------------
  // Copy just the snapshot elsewhere and open it on its own: a snapshot that
  // depended on a WAL sidecar would not open cleanly.
  const detached = path.join(tempDir, "detached.sqlite");
  fs.copyFileSync(snapshot1, detached);
  const verify = await cli(["verify", detached]);
  check(verify.code === 0, "snapshot verifies on its own", verify.output);

  // --- backup again, after the server has written more --------------------
  const save = await api(
    "PUT",
    `/characters/${characterId}`,
    { data: makeSave(heroName, "Mage", 9, 9999) },
    regA.json.token,
  );
  check(save.status === 200, "save a character", `status ${save.status}`);

  const backup2 = await cli(["backup"]);
  check(backup2.code === 0, "second backup succeeds with the server running", backup2.output);
  check(
    backup2.output.includes("accounts: 2"),
    "second backup sees the committed data",
    backup2.output.trim(),
  );
  check(snapshots().length === 2, "two snapshots exist", snapshots().join(", "));

  // --- restore (the server must be stopped for this) -----------------------
  await stopServer();

  const restore = await cli(["restore", snapshot1]);
  check(restore.code === 0, "restore command succeeds", restore.output);
  check(
    restore.output.includes("Pre-restore copy"),
    "restore reports a safety copy",
    restore.output.trim(),
  );
  check(
    snapshots().some((n) => n.includes("prerestore")),
    "restore kept a pre-restore snapshot",
    snapshots().join(", "),
  );

  // The snapshot predates the save above, so the restored level must be the
  // older one.
  await startServer();
  const afterRestore = await api("GET", `/characters/${characterId}`, undefined, regA.json.token);
  check(afterRestore.status === 200, "character is readable after the restore", `status ${afterRestore.status}`);
  check(
    afterRestore.json?.character?.level === 7,
    "restore rolled the character back to the snapshotted state",
    `level ${afterRestore.json?.character?.level}`,
  );

  const listed = await cli(["list"]);
  check(listed.code === 0, "list works after a restore", listed.output);
  check(
    listed.output.includes(alice) && listed.output.includes(bob),
    "both accounts survive the restore",
    listed.output.trim(),
  );

  // --- a restore must refuse to run against a database the server holds ----
  const blocked = await cli(["restore", snapshot1]);
  check(
    blocked.code === 1 && blocked.output.includes("running"),
    "restore is blocked while the server has the database open",
    blocked.output.trim(),
  );

  // --- pruning ------------------------------------------------------------
  const pruned = await cli(["backup", "--keep", "1"]);
  check(pruned.code === 0, "backup --keep runs", pruned.output);
  check(snapshots().length === 1, "pruning keeps only the newest snapshot", snapshots().join(", "));

  // --- a corrupt snapshot must be rejected ---------------------------------
  const corrupt = path.join(tempDir, "corrupt.sqlite");
  fs.writeFileSync(corrupt, "this is not a database");
  const bad = await cli(["verify", corrupt]);
  check(bad.code === 1, "verify rejects a file that is not a database", bad.output.trim());

  // --- the health endpoint reports a database fingerprint ------------------
  const health = await api("GET", "/health");
  check(
    typeof health.json.db_id === "string" && health.json.db_id.length === 16,
    "health reports a database fingerprint",
    JSON.stringify(health.json),
  );
} catch (error) {
  failures += 1;
  console.log(`FAIL: unexpected error - ${error.message}`);
} finally {
  await stopServer();
  fs.rmSync(tempDir, { recursive: true, force: true });
}

console.log(`\n${checks - failures}/${checks} checks passed.`);
process.exit(failures > 0 ? 1 : 0);
