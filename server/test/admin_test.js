/**
 * Admin CLI tests: account inspection, bans, mutes, password changes,
 * username and character renames, and account deletion.
 *
 * Runs entirely in a throwaway data directory so the real server database is
 * never touched.
 */
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { fileURLToPath } from "node:url";
import bcrypt from "bcryptjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const serverRoot = path.resolve(here, "..");
const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "emberfall-admin-test-"));
const dbPath = path.join(tempDir, "test.sqlite");
const port = 7596;

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
    EMBERFALL_JWT_SECRET: "test-secret-only",
    EMBERFALL_QUIET: "1",
    ...extra,
  };
}

/** Runs the admin CLI. `input` is written to stdin when given. */
function cli(args, input) {
  return new Promise((resolve) => {
    const child = spawn(
      process.execPath,
      [path.join(serverRoot, "src", "admin.js"), ...args],
      {
        env: env(),
        stdio: [input === undefined ? "ignore" : "pipe", "pipe", "pipe"],
      },
    );
    let output = "";
    child.stdout.on("data", (chunk) => (output += chunk));
    child.stderr.on("data", (chunk) => (output += chunk));
    if (input !== undefined) child.stdin.end(input);
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

/**
 * Reads a row straight from the test database.
 *
 * The login route is rate limited to 5 attempts a minute, so the tests check
 * stored credentials here instead of spending attempts on the API.
 */
function readRow(sql, ...params) {
  const db = new DatabaseSync(dbPath, { readOnly: true });
  try {
    return db.prepare(sql).get(...params);
  } finally {
    db.close();
  }
}

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
  const bob = `bob_${suffix}`.slice(0, 20);

  const regAlice = await api("POST", "/register", {
    username: alice,
    password: "password123",
  });
  await api("POST", "/register", { username: bob, password: "password123" });

  // --- list ---------------------------------------------------------------
  const list = await cli(["list"]);
  check(list.code === 0, "list succeeds", list.output);
  check(
    list.output.includes(alice) && list.output.includes(bob),
    "list shows both accounts",
    list.output.trim(),
  );

  // --- characters ---------------------------------------------------------
  const created = await api(
    "POST",
    "/characters",
    {
      name: `Hero_${suffix}`.slice(0, 20),
      class: "Mage",
    },
    regAlice.json?.token,
  );
  check(created.status === 201, "create a character", `status ${created.status}`);

  const chars = await cli(["characters", alice]);
  check(chars.code === 0, "characters succeeds", chars.output);
  check(chars.output.includes("Hero_"), "characters lists the character", chars.output.trim());

  const noSuch = await cli(["characters", "does_not_exist"]);
  check(noSuch.code === 1, "characters rejects an unknown account", noSuch.output.trim());

  // --- ban / unban --------------------------------------------------------
  await cli(["ban", alice, "testing"]);
  const afterBan = await cli(["list"]);
  check(
    afterBan.output.includes("true"),
    "ban sets the banned flag",
    afterBan.output.trim(),
  );

  const bannedLogin = await api("POST", "/login", {
    username: alice,
    password: "password123",
  });
  check(bannedLogin.status === 403, "a banned account cannot log in", `status ${bannedLogin.status}`);

  await cli(["unban", alice]);
  const afterUnban = await cli(["list"]);
  const unbanRow = afterUnban.output
    .split("\n")
    .find((line) => line.includes(alice));
  check(
    unbanRow && !/\btrue\b/.test(unbanRow),
    "unban clears the banned flag",
    unbanRow?.trim(),
  );

  const afterUnbanLogin = await api("POST", "/login", {
    username: alice,
    password: "password123",
  });
  check(
    afterUnbanLogin.status === 200,
    "the account can log in again after an unban",
    `status ${afterUnbanLogin.status}`,
  );

  // --- mute / unmute ------------------------------------------------------
  await cli(["mute", alice, "testing"]);
  const muted = await cli(["list"]);
  const muteRow = muted.output.split("\n").find((line) => line.includes(alice));
  check(muteRow && /\btrue\b/.test(muteRow), "mute sets the muted flag", muteRow?.trim());

  await cli(["unmute", alice]);
  const unmuted = await cli(["list"]);
  const unmuteRow = unmuted.output.split("\n").find((line) => line.includes(alice));
  check(
    unmuteRow && !/\btrue\b/.test(unmuteRow),
    "unmute clears the muted flag",
    unmuteRow?.trim(),
  );

  // --- setpassword --------------------------------------------------------
  const setPass = await cli(["setpassword", alice, "brandnewpass"]);
  check(setPass.code === 0, "setpassword succeeds", setPass.output);

  const oldLogin = await api("POST", "/login", {
    username: alice,
    password: "password123",
  });
  check(oldLogin.status === 401, "the old password no longer works", `status ${oldLogin.status}`);

  const newLogin = await api("POST", "/login", {
    username: alice,
    password: "brandnewpass",
  });
  check(newLogin.status === 200, "the new password works", `status ${newLogin.status}`);

  const shortPass = await cli(["setpassword", alice, "abc"]);
  check(shortPass.code === 1, "setpassword rejects a short password", shortPass.output.trim());

  const shortAllowed = await cli(["setpassword", alice, "abc", "--allow-short"]);
  check(shortAllowed.code === 0, "setpassword --allow-short succeeds", shortAllowed.output);

  const shortRow = readRow(
    "SELECT password_hash FROM accounts WHERE username = ?",
    alice,
  );
  check(
    !!shortRow && bcrypt.compareSync("abc", shortRow.password_hash),
    "the short password is stored and verifies",
    shortRow ? "hash mismatch" : "no row",
  );

  const emptyPass = await cli(["setpassword", alice, "", "--allow-short"]);
  check(emptyPass.code === 1, "setpassword refuses an empty password", emptyPass.output.trim());

  // Put the long password back for the checks that follow.
  await cli(["setpassword", alice, "brandnewpass"]);

  // --- query --------------------------------------------------------------
  // Runs before the delete block, while the account and its character exist.
  const query = await cli(["query", "SELECT id, username FROM accounts"]);
  check(query.code === 0, "query succeeds", query.output);
  check(query.output.includes(alice), "query returns the account", query.output.trim());
  check(query.output.includes("row(s)"), "query reports the row count", query.output.trim());

  const joined = await cli([
    "query",
    "SELECT c.name, a.username FROM characters c JOIN accounts a ON a.id = c.account_id",
  ]);
  check(joined.code === 0, "query handles a join", joined.output);
  check(joined.output.includes("Hero_"), "query returns the joined row", joined.output.trim());

  const refused = await cli(["query", "DELETE FROM accounts"]);
  check(refused.code === 1, "query refuses a write", refused.output.trim());
  check(
    refused.output.includes("read-only"),
    "query explains that writes are refused",
    refused.output.trim(),
  );

  const stillThere2 = await cli(["list"]);
  check(stillThere2.output.includes(bob), "the refused write changed nothing", stillThere2.output.trim());

  const broken = await cli(["query", "SELECT * FROM no_such_table"]);
  check(broken.code === 1, "query reports a bad statement", broken.output.trim());

  // --- setusername --------------------------------------------------------
  const aliceRenamed = `bento_${suffix}`.slice(0, 20);
  const setName = await cli(["setusername", alice, aliceRenamed]);
  check(setName.code === 0, "setusername succeeds", setName.output);

  const renamedRow = readRow("SELECT username FROM accounts WHERE username = ?", aliceRenamed);
  check(
    renamedRow?.username === aliceRenamed,
    "the account row carries the new username",
    renamedRow?.username,
  );

  const oldNameGone = await cli(["characters", alice]);
  check(oldNameGone.code === 1, "the old username no longer resolves", oldNameGone.output.trim());

  const newNameWorks = await cli(["characters", aliceRenamed]);
  check(newNameWorks.code === 0, "the new username resolves", newNameWorks.output);

  const badName = await cli(["setusername", aliceRenamed, "a"]);
  check(badName.code === 1, "setusername rejects an invalid username", badName.output.trim());

  const takenName = await cli(["setusername", aliceRenamed, bob]);
  check(takenName.code === 1, "setusername rejects a taken username", takenName.output.trim());

  const missingAccount = await cli(["setusername", "does_not_exist", "whatever"]);
  check(missingAccount.code === 1, "setusername rejects an unknown account", missingAccount.output.trim());

  // --- renamecharacter ----------------------------------------------------
  const hero = `Hero_${suffix}`.slice(0, 20);
  const heroRenamed = `Hero2_${suffix}`.slice(0, 20);
  const renamed = await cli(["renamecharacter", aliceRenamed, hero, heroRenamed]);
  check(renamed.code === 0, "renamecharacter succeeds", renamed.output);

  const charRow = readRow(
    "SELECT name, data FROM characters WHERE account_id = (SELECT id FROM accounts WHERE username = ?)",
    aliceRenamed,
  );
  check(charRow?.name === heroRenamed, "the character row carries the new name", charRow?.name);
  check(
    typeof charRow?.data === "string" && charRow.data.includes(heroRenamed),
    "the save blob carries the new name",
    charRow?.data?.slice(0, 120),
  );
  check(
    typeof charRow?.data === "string" && !charRow.data.includes(`"${hero}"`),
    "the save blob no longer carries the old name",
    charRow?.data?.slice(0, 120),
  );

  const missingHero = await cli(["renamecharacter", aliceRenamed, "NoSuchHero", hero]);
  check(missingHero.code === 1, "renamecharacter rejects a missing character", missingHero.output.trim());

  // --- delete -------------------------------------------------------------
  const cancelled = await cli(["delete", aliceRenamed], "n\n");
  check(cancelled.code === 0, "delete runs", cancelled.output);
  check(cancelled.output.includes("Cancelled"), "delete can be cancelled", cancelled.output.trim());

  const stillThere = await cli(["list"]);
  check(
    stillThere.output.includes(aliceRenamed),
    "a cancelled delete keeps the account",
    stillThere.output.trim(),
  );

  const deleted = await cli(["delete", aliceRenamed, "--yes"]);
  check(deleted.code === 0, "delete --yes succeeds", deleted.output);

  const gone = await cli(["list"]);
  check(!gone.output.includes(aliceRenamed), "the account is gone", gone.output.trim());

  const goneChars = await cli(["characters", aliceRenamed]);
  check(goneChars.code === 1, "the account's characters are gone", goneChars.output.trim());

  const deleteMissing = await cli(["delete", "does_not_exist", "--yes"]);
  check(deleteMissing.code === 1, "delete rejects an unknown account", deleteMissing.output.trim());
} catch (error) {
  failures += 1;
  console.log(`FAIL: unexpected error - ${error.message}`);
} finally {
  await stopServer();
  fs.rmSync(tempDir, { recursive: true, force: true });
}

console.log(`\n${checks - failures}/${checks} checks passed.`);
process.exit(failures > 0 ? 1 : 0);
