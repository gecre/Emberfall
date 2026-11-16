/**
 * Backup and restore helpers for the Emberfall SQLite database.
 *
 * The server runs the database in WAL mode, so the `.sqlite` file on its own is
 * NOT a complete copy of the data while the server is running: everything
 * written since the last checkpoint still lives in the `-wal` sidecar. Copying
 * the main file by hand would silently roll the database back to an older
 * state (in practice, close to empty).
 *
 * `VACUUM INTO` writes a fresh, self-contained database file that includes the
 * committed WAL content, and it is safe to run against a live server.
 */
import fs from "node:fs";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { BACKUP_KEEP, BACKUP_DIR, DATA_DIR, DB_PATH } from "./config.js";

/** Tables a snapshot must contain before it is considered restorable. */
const REQUIRED_TABLES = ["accounts", "characters", "items"];

/** Escapes a value for use as a single-quoted SQL literal. */
function quoteLiteral(value) {
  return String(value).replace(/'/g, "''");
}

/**
 * Filename for a snapshot. The timestamp is ISO-8601 with separators swapped
 * for `-`/`_` and millisecond precision, so the name sorts chronologically as
 * a plain string and two snapshots in the same second never collide.
 */
export function backupFileName(date = new Date(), tag = "") {
  const stamp = date
    .toISOString()
    .replace(/[:.]/g, "-")
    .replace("T", "_")
    .slice(0, 23);
  return `emberfall-${stamp}${tag ? `-${tag}` : ""}.sqlite`;
}

/**
 * Creates a consistent snapshot of the live database.
 *
 * @returns {string} absolute path of the snapshot file
 */
export function createBackup({
  outDir = BACKUP_DIR,
  dbPath = DB_PATH,
  now = new Date(),
  tag = "",
} = {}) {
  if (!fs.existsSync(dbPath)) {
    throw new Error(`Database not found at ${dbPath}`);
  }
  fs.mkdirSync(outDir, { recursive: true });

  // Nudge the timestamp forward until the name is free, so two snapshots
  // taken in the same millisecond cannot overwrite each other.
  let taken = new Date(now);
  let target = path.join(outDir, backupFileName(taken, tag));
  for (let bump = 1; fs.existsSync(target); bump += 1) {
    taken = new Date(now.getTime() + bump);
    target = path.join(outDir, backupFileName(taken, tag));
  }

  const source = new DatabaseSync(dbPath);
  try {
    // VACUUM INTO produces a defragmented, self-contained copy that includes
    // everything committed to the WAL.
    source.exec(`VACUUM INTO '${quoteLiteral(target)}'`);
  } finally {
    source.close();
  }

  const report = verifyBackup(target);
  writeManifest(target, {
    created_at: taken.toISOString(),
    source: dbPath,
    tag: tag || null,
    counts: report.counts,
    size: report.size,
  });
  return target;
}

/** Writes the sidecar manifest that describes a snapshot. */
function writeManifest(backupFile, manifest) {
  fs.writeFileSync(
    backupFile.replace(/\.sqlite$/, ".json"),
    `${JSON.stringify(manifest, null, 2)}\n`,
  );
}

/** Lists the snapshots in a directory, oldest first. */
export function listBackups(outDir = BACKUP_DIR) {
  if (!fs.existsSync(outDir)) return [];
  return fs
    .readdirSync(outDir)
    .filter((name) => name.endsWith(".sqlite"))
    .sort()
    .map((name) => {
      const file = path.join(outDir, name);
      const stat = fs.statSync(file);
      const manifestFile = file.replace(/\.sqlite$/, ".json");
      let manifest = null;
      if (fs.existsSync(manifestFile)) {
        try {
          manifest = JSON.parse(fs.readFileSync(manifestFile, "utf8"));
        } catch {
          manifest = null;
        }
      }
      return {
        name,
        file,
        size: stat.size,
        modified: stat.mtime.toISOString(),
        manifest,
      };
    });
}

/**
 * Deletes the oldest snapshots so that at most `keep` remain.
 *
 * @returns {string[]} the files that were deleted
 */
export function pruneBackups({ outDir = BACKUP_DIR, keep = BACKUP_KEEP } = {}) {
  const backups = listBackups(outDir);
  if (backups.length <= keep) return [];
  const doomed = backups.slice(0, backups.length - keep);
  for (const backup of doomed) {
    fs.rmSync(backup.file, { force: true });
    fs.rmSync(backup.file.replace(/\.sqlite$/, ".json"), { force: true });
  }
  return doomed.map((backup) => backup.file);
}

/**
 * Integrity-checks a snapshot and confirms it can be restored.
 *
 * @returns {{ok: true, integrity: string, counts: object, size: number}}
 */
export function verifyBackup(file) {
  const absolute = path.resolve(file);
  if (!fs.existsSync(absolute)) {
    throw new Error(`Backup not found: ${absolute}`);
  }
  const db = new DatabaseSync(absolute, { readOnly: true });
  try {
    const integrity = db.prepare("PRAGMA integrity_check").get();
    if (!integrity || integrity.integrity_check !== "ok") {
      throw new Error(
        `Integrity check failed: ${JSON.stringify(integrity?.integrity_check)}`,
      );
    }
    const tables = db
      .prepare("SELECT name FROM sqlite_master WHERE type = 'table'")
      .all()
      .map((row) => row.name);
    const missing = REQUIRED_TABLES.filter((table) => !tables.includes(table));
    if (missing.length > 0) {
      throw new Error(`Backup is missing tables: ${missing.join(", ")}`);
    }
    const counts = {};
    for (const table of REQUIRED_TABLES) {
      counts[table] = db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get().n;
    }
    return {
      ok: true,
      integrity: "ok",
      counts,
      size: fs.statSync(absolute).size,
    };
  } finally {
    db.close();
  }
}

/**
 * Replaces the live database file with a copy of `source`.
 *
 * The `-wal` and `-shm` sidecars are removed as well: a stale WAL would
 * replay old pages on top of the restored file. The copy is staged next to
 * the target first, so the database is only ever missing for an instant.
 *
 * The caller must close its own handle to the database before calling this.
 */
export function replaceDatabaseFile(source, { dbPath = DB_PATH } = {}) {
  const absolute = path.resolve(source);
  const staged = `${dbPath}.restore-tmp`;
  try {
    fs.copyFileSync(absolute, staged);
    for (const suffix of ["", "-wal", "-shm"]) {
      fs.rmSync(`${dbPath}${suffix}`, { force: true });
    }
    fs.renameSync(staged, dbPath);
  } catch (error) {
    fs.rmSync(staged, { force: true });
    if (error.code === "EPERM" || error.code === "EBUSY") {
      throw new Error(
        "The database file is locked. Stop the server and restore from the " +
          "command line.",
      );
    }
    throw error;
  }
}

/**
 * Restores a snapshot over the live database.
 *
 * The current database is snapshotted first so the restore can be undone, then
 * the live file (and its `-wal`/`-shm` sidecars) is replaced. The sidecars
 * must go: a stale WAL would replay old pages on top of the restored file.
 *
 * The server must be stopped while this runs, otherwise it keeps writing to
 * the old file and the restore is lost the moment it commits.
 */
export function restoreBackup(
  file,
  { dbPath = DB_PATH, outDir = BACKUP_DIR, now = new Date() } = {},
) {
  const report = verifyBackup(file);
  const source = path.resolve(file);

  // Safety net: keep the pre-restore state so this can be undone.
  const safetyCopy = createBackup({
    outDir,
    dbPath,
    now,
    tag: "prerestore",
  });

  replaceDatabaseFile(source, { dbPath });

  // Confirm what actually landed on disk.
  const restored = verifyBackup(dbPath);

  // A snapshot is written with the default journal mode; put the restored
  // database back into WAL so it matches how the server expects to find it.
  const reopened = new DatabaseSync(dbPath);
  try {
    reopened.exec("PRAGMA journal_mode = WAL");
  } finally {
    reopened.close();
  }

  return { ...report, restored, safetyCopy };
}

/** Absolute path of the directory snapshots are written to. */
export function defaultBackupDir() {
  return path.join(DATA_DIR, "backups");
}
