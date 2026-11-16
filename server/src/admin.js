#!/usr/bin/env node
/**
 * Small admin CLI for the Emberfall server.
 *
 *   node src/admin.js list
 *   node src/admin.js characters <username>
 *   node src/admin.js ban <username> <reason...>
 *   node src/admin.js unban <username>
 *   node src/admin.js mute <username> <reason...>
 *   node src/admin.js unmute <username>
 *   node src/admin.js setpassword <username> <password> [--allow-short]
 *   node src/admin.js setusername <username> <newusername>
 *   node src/admin.js renamecharacter <username> <oldname> <newname>
 *   node src/admin.js delete <username> [--yes]
 *   node src/admin.js backup [--keep N] [--out <dir>]
 *   node src/admin.js backups
 *   node src/admin.js verify <backup-file>
 *   node src/admin.js restore <backup-file> [--force]
 *   node src/admin.js query "<sql>" [--snapshot <backup-file>]
 *
 * The database is the same one the API uses, so run this with the same
 * EMBERFALL_DB / EMBERFALL_DATA_DIR environment as the server.
 */
import fs from "node:fs";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import {
  createBackup,
  listBackups,
  pruneBackups,
  restoreBackup,
  verifyBackup,
} from "./backup.js";
import {
  BACKUP_DIR,
  BACKUP_KEEP,
  DB_PATH,
  HOST,
  PORT,
  dbFingerprint,
} from "./config.js";

function usage() {
  console.log(`Emberfall admin

Usage:
  node src/admin.js list                       List accounts
  node src/admin.js characters <username>      List an account's characters
  node src/admin.js ban <username> <reason>    Ban an account
  node src/admin.js unban <username>           Lift a ban
  node src/admin.js mute <username> <reason>   Mute an account
  node src/admin.js unmute <username>          Lift a mute
  node src/admin.js setpassword <user> <pass>  Replace an account password
                       [--allow-short]         Skip the 6 character minimum
  node src/admin.js setusername <user> <name>  Rename an account
  node src/admin.js renamecharacter <user> <old> <new>
                                              Rename one of its characters
  node src/admin.js delete <username> [--yes]  Delete an account + characters
  node src/admin.js backup [--keep N]          Snapshot the database
  node src/admin.js backups                    List snapshots
  node src/admin.js verify <file>              Check a snapshot is restorable
  node src/admin.js restore <file>             Restore a snapshot
  node src/admin.js query "<sql>"              Run a read-only SQL query
`);
}

/**
 * Runs a command against the live database.
 *
 * db.js opens the database file on import, so it is loaded lazily: the backup
 * and restore commands must be able to replace that file and cannot afford an
 * open connection to it.
 */
async function withDb(fn) {
  const { db, findAccountByUsername, findCharacterByName, listCharacters, parseJson } =
    await import("./db.js");
  try {
    return await fn({
      db,
      findAccountByUsername,
      findCharacterByName,
      listCharacters,
      parseJson,
    });
  } finally {
    db.close();
  }
}

function requireAccount(ctx, username) {
  const account = ctx.findAccountByUsername(username);
  if (!account) {
    console.error(`No account named "${username}".`);
    process.exit(1);
  }
  return account;
}

function listAccounts(ctx) {
  const rows = ctx.db
    .prepare(
      `SELECT id, username, banned, muted, created_at, last_login
       FROM accounts ORDER BY id`,
    )
    .all();
  if (rows.length === 0) {
    console.log("No accounts yet.");
    return;
  }
  console.log("id  username           banned  muted  created             last login");
  for (const row of rows) {
    console.log(
      `${String(row.id).padEnd(3)} ${String(row.username).padEnd(18)} ` +
        `${String(!!row.banned).padEnd(7)} ${String(!!row.muted).padEnd(6)} ` +
        `${String(row.created_at).padEnd(19)} ${row.last_login ?? "-"}`,
    );
  }
}

function listAccountCharacters(ctx, username) {
  const account = requireAccount(ctx, username);
  const rows = ctx.listCharacters(account.id);
  if (rows.length === 0) {
    console.log(`"${username}" has no characters.`);
    return;
  }
  console.log("id  name               class     level  stage  gold");
  for (const row of rows) {
    console.log(
      `${String(row.id).padEnd(3)} ${String(row.name).padEnd(18)} ` +
        `${String(row.class).padEnd(9)} ${String(row.level).padEnd(6)} ` +
        `${String(row.current_stage).padEnd(6)} ${row.gold}`,
    );
  }
}

function ban(ctx, username, reason) {
  const account = requireAccount(ctx, username);
  ctx.db
    .prepare("UPDATE accounts SET banned = 1, ban_reason = ? WHERE id = ?")
    .run(reason, account.id);
  ctx.db
    .prepare(
      `INSERT INTO bans (account_id, reason, created_by) VALUES (?, ?, 'admin')`,
    )
    .run(account.id, reason);
  console.log(`Banned "${username}": ${reason}`);
}

function unban(ctx, username) {
  const account = requireAccount(ctx, username);
  ctx.db
    .prepare("UPDATE accounts SET banned = 0, ban_reason = NULL WHERE id = ?")
    .run(account.id);
  ctx.db.prepare("DELETE FROM bans WHERE account_id = ?").run(account.id);
  console.log(`Unbanned "${username}".`);
}

function mute(ctx, username, reason) {
  const account = requireAccount(ctx, username);
  ctx.db
    .prepare("UPDATE accounts SET muted = 1, mute_reason = ? WHERE id = ?")
    .run(reason, account.id);
  ctx.db
    .prepare(
      `INSERT INTO mutes (account_id, reason, created_by) VALUES (?, ?, 'admin')`,
    )
    .run(account.id, reason);
  console.log(`Muted "${username}": ${reason}`);
}

function unmute(ctx, username) {
  const account = requireAccount(ctx, username);
  ctx.db
    .prepare("UPDATE accounts SET muted = 0, mute_reason = NULL WHERE id = ?")
    .run(account.id);
  ctx.db.prepare("DELETE FROM mutes WHERE account_id = ?").run(account.id);
  console.log(`Unmuted "${username}".`);
}

async function setPassword(ctx, username, password, allowShort = false) {
  const account = requireAccount(ctx, username);
  if (typeof password !== "string" || password.length === 0) {
    console.error("The password cannot be empty.");
    process.exit(1);
  }
  if (!allowShort && password.length < 6) {
    console.error(
      "The password must be at least 6 characters. Pass --allow-short to " +
        "set a shorter one on an existing account.",
    );
    process.exit(1);
  }
  if (password.length > 72) {
    console.error("The password must be 72 characters or fewer.");
    process.exit(1);
  }
  // Loaded lazily: auth.js generates the JWT secret file on import.
  const { hashPassword } = await import("./auth.js");
  ctx.db
    .prepare("UPDATE accounts SET password_hash = ? WHERE id = ?")
    .run(hashPassword(password), account.id);
  console.log(`Password changed for "${username}".`);
}

/**
 * Renames an account.
 *
 * The username is stored case-insensitively, so the new name must not collide
 * with another account. The account id is unchanged, which keeps the
 * characters and the issued tokens attached to it.
 */
async function setUsername(ctx, username, newUsername) {
  const account = requireAccount(ctx, username);
  const { validateUsername } = await import("./validate.js");
  const clean = typeof newUsername === "string" ? newUsername.trim() : "";
  const problem = validateUsername(clean);
  if (problem) {
    console.error(problem);
    process.exit(1);
  }
  if (clean.toLowerCase() === account.username.toLowerCase()) {
    console.log(`"${account.username}" already has that username.`);
    return;
  }
  const taken = ctx.findAccountByUsername(clean);
  if (taken && taken.id !== account.id) {
    console.error(`The username "${clean}" is already taken.`);
    process.exit(1);
  }
  ctx.db
    .prepare("UPDATE accounts SET username = ? WHERE id = ?")
    .run(clean, account.id);
  console.log(`Username changed: "${account.username}" -> "${clean}".`);
}

/**
 * Renames one of an account's characters.
 *
 * The name is stored twice: in the character row and inside the save blob as
 * player_name. The blob is rewritten as well, otherwise the next cloud save
 * would push the old name back to the server.
 */
async function renameCharacter(ctx, username, oldName, newName) {
  const account = requireAccount(ctx, username);
  const { validateCharacterName } = await import("./validate.js");
  const clean = typeof newName === "string" ? newName.trim() : "";
  const problem = validateCharacterName(clean);
  if (problem) {
    console.error(problem);
    process.exit(1);
  }
  const character = ctx.db
    .prepare(
      `SELECT id, name, data FROM characters
       WHERE account_id = ? AND name = ? COLLATE NOCASE`,
    )
    .get(account.id, oldName);
  if (!character) {
    console.error(`"${username}" has no character named "${oldName}".`);
    process.exit(1);
  }
  const taken = ctx.findCharacterByName(clean);
  if (taken && taken.id !== character.id) {
    console.error(`The character name "${clean}" is already taken.`);
    process.exit(1);
  }

  const data = ctx.parseJson(character.data, {});
  if (data && typeof data === "object") {
    data.player_name = clean;
  }
  ctx.db
    .prepare(
      `UPDATE characters
       SET name = ?, data = ?, updated_at = datetime('now')
       WHERE id = ?`,
    )
    .run(clean, JSON.stringify(data), character.id);
  console.log(`Character renamed: "${character.name}" -> "${clean}".`);
}

function deleteAccount(ctx, username, assumeYes) {
  const account = requireAccount(ctx, username);
  const characters = ctx.listCharacters(account.id);
  console.log(
    `"${username}" (id ${account.id}, created ${account.created_at}) ` +
      `owns ${characters.length} character(s).`,
  );
  for (const character of characters) {
    console.log(`  - ${character.name} (${character.class}, level ${character.level})`);
  }

  if (!assumeYes) {
    const answer = prompt(
      `Delete "${username}" and ${characters.length} character(s) permanently? [y/N] `,
    );
    if (answer !== "y" && answer !== "yes") {
      console.log("Cancelled.");
      return;
    }
  }

  // characters.bans/mutes cascade from the account.
  ctx.db.prepare("DELETE FROM accounts WHERE id = ?").run(account.id);
  console.log(`Deleted "${username}".`);
}

/** Reads a line from stdin. Returns an empty string when there is no stdin. */
function prompt(question) {
  process.stdout.write(question);
  const buffer = Buffer.alloc(256);
  try {
    const read = fs.readSync(0, buffer, 0, 256, null);
    return buffer.toString("utf8", 0, read).trim().toLowerCase();
  } catch {
    return "";
  }
}

// ---------------------------------------------------------------------------
// Query
// ---------------------------------------------------------------------------

/** Renders rows as an aligned table, or as a plain list for one column. */
function formatTable(rows) {
  if (rows.length === 0) return "(no rows)";
  const columns = Object.keys(rows[0]);
  if (columns.length === 1) {
    return rows.map((row) => String(row[columns[0]])).join("\n");
  }
  const widths = columns.map((column) =>
    Math.max(
      column.length,
      ...rows.map((row) => String(row[column] ?? "").length),
    ),
  );
  const line = (values) =>
    values
      .map((value, index) => String(value ?? "").padEnd(widths[index]))
      .join("  ")
      .trimEnd();
  return [
    line(columns),
    widths.map((width) => "-".repeat(width)).join("  "),
    ...rows.map((row) => line(columns.map((column) => row[column]))),
  ].join("\n");
}

function runQuery(sql, snapshotFile) {
  if (!sql || !sql.trim()) {
    console.error("query needs a SQL statement.");
    process.exit(1);
  }
  const statement = sql.trim().replace(/;+\s*$/, "");
  if (!/^(select|with|pragma|explain)\b/i.test(statement)) {
    console.error(
      "Only read-only statements are allowed here (SELECT, WITH, PRAGMA, EXPLAIN).",
    );
    process.exit(1);
  }

  const target = snapshotFile ? path.resolve(snapshotFile) : DB_PATH;
  if (!fs.existsSync(target)) {
    console.error(`Database not found: ${target}`);
    process.exit(1);
  }

  // Opened read-only, so the statement cannot modify anything even if the
  // guard above were bypassed.
  const db = new DatabaseSync(target, { readOnly: true });
  try {
    const rows = db.prepare(statement).all();
    console.log(formatTable(rows));
    console.log(`\n${rows.length} row(s)`);
  } catch (error) {
    console.error(`Query failed: ${error.message}`);
    process.exit(1);
  } finally {
    db.close();
  }
}

// ---------------------------------------------------------------------------
// Backup / restore
// ---------------------------------------------------------------------------

function formatBytes(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function runBackup(args) {
  const options = { outDir: BACKUP_DIR, keep: BACKUP_KEEP };
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (arg === "--keep") {
      options.keep = Number.parseInt(args[++i], 10);
      if (!Number.isInteger(options.keep) || options.keep < 1) {
        console.error("--keep needs a positive number.");
        process.exit(1);
      }
    } else if (arg === "--out") {
      options.outDir = path.resolve(args[++i] ?? "");
    } else {
      console.error(`Unknown option: ${arg}`);
      process.exit(1);
    }
  }

  const target = createBackup(options);
  const report = verifyBackup(target);
  console.log(`Backup written: ${target}`);
  console.log(
    `  size: ${formatBytes(report.size)}  ` +
      `accounts: ${report.counts.accounts}  ` +
      `characters: ${report.counts.characters}  ` +
      `items: ${report.counts.items}`,
  );

  const pruned = pruneBackups(options);
  if (pruned.length > 0) {
    console.log(`Pruned ${pruned.length} old snapshot(s), keeping ${options.keep}.`);
  }
}

function listBackupFiles() {
  const backups = listBackups(BACKUP_DIR);
  if (backups.length === 0) {
    console.log(`No snapshots in ${BACKUP_DIR}`);
    return;
  }
  console.log("snapshot                       size      created              accounts  characters");
  for (const backup of backups) {
    const counts = backup.manifest?.counts;
    console.log(
      `${backup.name.padEnd(30)} ${formatBytes(backup.size).padEnd(9)} ` +
        `${backup.modified.padEnd(19)} ` +
        `${String(counts?.accounts ?? "?").padEnd(9)} ` +
        `${String(counts?.characters ?? "?")}`,
    );
  }
}

function runVerify(file) {
  if (!file) {
    console.error("verify needs a file.");
    process.exit(1);
  }
  const report = verifyBackup(file);
  console.log(`OK: ${path.resolve(file)}`);
  console.log(
    `  integrity: ${report.integrity}  size: ${formatBytes(report.size)}  ` +
      `accounts: ${report.counts.accounts}  ` +
      `characters: ${report.counts.characters}  ` +
      `items: ${report.counts.items}`,
  );
}

/**
 * True when a running API server has the same database file open that this
 * command would replace. The server reports a fingerprint of its database
 * path, so restoring into an unrelated database is never blocked.
 */
async function serverUsingThisDatabase() {
  const host = HOST === "0.0.0.0" || HOST === "::" ? "127.0.0.1" : HOST;
  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 1500);
    const response = await fetch(`http://${host}:${PORT}/api/health`, {
      signal: controller.signal,
    });
    clearTimeout(timer);
    if (!response.ok) return false;
    const health = await response.json();
    return health.db_id === dbFingerprint();
  } catch {
    return false;
  }
}

async function runRestore(file, force) {
  if (!file) {
    console.error("restore needs a file.");
    process.exit(1);
  }

  const report = verifyBackup(file);
  console.log(
    `Restoring ${path.resolve(file)} ` +
      `(accounts: ${report.counts.accounts}, characters: ${report.counts.characters})`,
  );

  if (!force && (await serverUsingThisDatabase())) {
    console.error(
      "The API server is running and has this database open. Stop it " +
        "(close the launcher window), then run the restore again " +
        "(add --force to skip this check).",
    );
    process.exit(1);
  }

  const result = restoreBackup(file);
  console.log(`Restored. accounts: ${result.restored.counts.accounts}, characters: ${result.restored.counts.characters}`);
  console.log(`Pre-restore copy: ${result.safetyCopy}`);
  console.log("Start the server again to use the restored database.");
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

const [command, ...rest] = process.argv.slice(2);

try {
  switch (command) {
    case "list":
      await withDb((ctx) => listAccounts(ctx));
      break;
    case "characters":
      if (!rest[0]) usage();
      else await withDb((ctx) => listAccountCharacters(ctx, rest[0]));
      break;
    case "ban":
      if (!rest[0] || !rest.slice(1).join(" ").trim()) usage();
      else
        await withDb((ctx) =>
          ban(ctx, rest[0], rest.slice(1).join(" ").trim()),
        );
      break;
    case "unban":
      if (!rest[0]) usage();
      else await withDb((ctx) => unban(ctx, rest[0]));
      break;
    case "mute":
      if (!rest[0] || !rest.slice(1).join(" ").trim()) usage();
      else
        await withDb((ctx) =>
          mute(ctx, rest[0], rest.slice(1).join(" ").trim()),
        );
      break;
    case "unmute":
      if (!rest[0]) usage();
      else await withDb((ctx) => unmute(ctx, rest[0]));
      break;
    case "setpassword": {
      const allowShort = rest.includes("--allow-short");
      const args = rest.filter((arg) => arg !== "--allow-short");
      if (args.length < 2) usage();
      else
        await withDb((ctx) =>
          setPassword(ctx, args[0], args.slice(1).join(" "), allowShort),
        );
      break;
    }
    case "setusername":
      if (rest.length < 2) usage();
      else await withDb((ctx) => setUsername(ctx, rest[0], rest[1]));
      break;
    case "renamecharacter":
      if (rest.length < 3) usage();
      else
        await withDb((ctx) =>
          renameCharacter(ctx, rest[0], rest[1], rest.slice(2).join(" ")),
        );
      break;
    case "delete":
      if (!rest[0]) usage();
      else
        await withDb((ctx) =>
          deleteAccount(ctx, rest[0], rest.includes("--yes")),
        );
      break;
    case "backup":
      runBackup(rest);
      break;
    case "backups":
      listBackupFiles();
      break;
    case "verify":
      runVerify(rest[0]);
      break;
    case "query": {
      // The SQL may arrive as one quoted argument or as several words;
      // everything that is not the --snapshot flag is joined back together.
      const parts = [...rest];
      let snapshot = null;
      const snapshotIndex = parts.indexOf("--snapshot");
      if (snapshotIndex >= 0) {
        snapshot = parts[snapshotIndex + 1];
        parts.splice(snapshotIndex, 2);
      }
      runQuery(parts.join(" "), snapshot);
      break;
    }
    case "restore":
      await runRestore(rest[0], rest.includes("--force"));
      break;
    default:
      usage();
      process.exit(command ? 1 : 0);
  }
} catch (error) {
  console.error(error?.message || error);
  process.exit(1);
}
