import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const serverRoot = path.resolve(here, "..");
const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "emberfall-test-"));
const port = 7598;
const base = `http://127.0.0.1:${port}/api`;

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

async function request(method, route, body, token) {
  const headers = {};
  if (body !== undefined) headers["Content-Type"] = "application/json";
  if (token) headers.Authorization = `Bearer ${token}`;
  const response = await fetch(`${base}${route}`, {
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

async function waitForServer() {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    try {
      const res = await fetch(`${base}/health`);
      if (res.ok) return;
    } catch {
      // not up yet
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error("server did not start");
}

const child = spawn(process.execPath, [path.join(serverRoot, "src", "index.js")], {
  env: {
    ...process.env,
    PORT: String(port),
    HOST: "127.0.0.1",
    EMBERFALL_DATA_DIR: tempDir,
    EMBERFALL_DB: path.join(tempDir, "test.sqlite"),
    EMBERFALL_JWT_SECRET: "test-secret-only",
    EMBERFALL_MAX_CHARACTERS: "2",
    EMBERFALL_QUIET: "1",
  },
  stdio: ["ignore", "pipe", "pipe"],
});

let serverLog = "";
child.stdout.on("data", (chunk) => (serverLog += chunk));
child.stderr.on("data", (chunk) => (serverLog += chunk));

try {
  await waitForServer();

  const suffix = Date.now().toString(36);
  const username = `tester_${suffix}`.slice(0, 20);
  const password = "hunter2secret";
  const characterName = `Hero${suffix}`.slice(0, 20);

  let res = await request("GET", "/health");
  check(res.status === 200 && res.json?.ok === true, "health endpoint responds");

  res = await request("POST", "/register", { username, password });
  check(res.status === 201 && typeof res.json?.token === "string", "register issues a token", JSON.stringify(res.json));
  const token = res.json?.token;

  res = await request("POST", "/register", { username, password });
  check(res.status === 409, "duplicate username rejected");

  res = await request("POST", "/login", { username, password: "wrong-password" });
  check(res.status === 401, "wrong password rejected");

  res = await request("POST", "/login", { username, password });
  check(res.status === 200 && Array.isArray(res.json?.characters), "login returns character list");

  res = await request("GET", "/characters");
  check(res.status === 401, "characters require a token");

  const { defaultCharacterData } = await import("../src/validate.js");
  const fresh = defaultCharacterData(characterName, "Warrior");
  fresh.inventory = [{ name: "Stick", qty: 1, locked: false }];

  res = await request("POST", "/characters", { name: characterName, class: "Warrior", data: fresh }, token);
  check(res.status === 201 && res.json?.character?.id, "character created", JSON.stringify(res.json));
  const characterId = res.json?.character?.id;

  res = await request("POST", "/characters", { name: characterName, class: "Warrior", data: fresh }, token);
  check(res.status === 409, "duplicate character name rejected");

  res = await request("GET", `/characters/${characterId}`, undefined, token);
  check(res.status === 200 && res.json?.character?.data?.player_name === characterName, "character loads full data");

  const saved = { ...fresh };
  saved.gold = 500;
  saved.xp = 25;
  saved.current_hp = 80;
  saved.play_time = 12.5;
  saved.attributes.strength = 2;
  saved.skills = { "Increased Jump Height": 1 };
  res = await request("PUT", `/characters/${characterId}`, { data: saved }, token);
  check(res.status === 200 && res.json?.character?.gold === 500, "valid save accepted", JSON.stringify(res.json));

  const greedy = { ...saved, gold: 500 + 500000 };
  res = await request("PUT", `/characters/${characterId}`, { data: greedy }, token);
  check(res.status === 400, "gold-gain cap rejects a cheat save");

  // Selling a valuable item explains a large gold jump, so it is accepted.
  const withHelmet = {
    ...saved,
    inventory: [{ name: "Bladed Helmet", qty: 1, locked: false }],
  };
  res = await request("PUT", `/characters/${characterId}`, { data: withHelmet }, token);
  check(res.status === 200, "a valuable item is stored", JSON.stringify(res.json));

  const afterSale = { ...saved, inventory: [], gold: 500 + 752500 };
  res = await request("PUT", `/characters/${characterId}`, { data: afterSale }, token);
  check(
    res.status === 200 && res.json?.character?.gold === 500 + 752500,
    "selling an item explains a large gold gain",
    JSON.stringify(res.json),
  );

  const badItem = { ...saved, gold: 500, inventory: [{ name: "Not A Real Item", qty: 1 }] };
  res = await request("PUT", `/characters/${characterId}`, { data: badItem }, token);
  check(res.status === 400, "unknown inventory item rejected");

  const badGold = { ...saved, gold: -5 };
  res = await request("PUT", `/characters/${characterId}`, { data: badGold }, token);
  check(res.status === 400, "negative gold rejected");

  const otherToken = (
    await request("POST", "/register", { username: `other_${suffix}`.slice(0, 20), password })
  ).json?.token;
  res = await request("GET", `/characters/${characterId}`, undefined, otherToken);
  check(res.status === 404, "characters are private to their account");

  res = await request("GET", "/items");
  check(res.status === 200 && res.json?.count === 728, "item catalog mirrored", String(res.json?.count));

  // ---- Second character, listing and deletion ----
  const secondName = `Second${suffix}`.slice(0, 20);
  const secondData = defaultCharacterData(secondName, "Archer");
  res = await request("POST", "/characters", { name: secondName, class: "Archer", data: secondData }, token);
  check(res.status === 201 && res.json?.character?.id, "a second character can be created");
  const secondId = res.json?.character?.id;

  res = await request("GET", "/characters", undefined, token);
  check(res.status === 200 && res.json?.characters?.length === 2, "the account lists both characters", String(res.json?.characters?.length));

  res = await request("DELETE", `/characters/${secondId}`, undefined, token);
  check(res.status === 200 && res.json?.deleted === secondId, "character deleted", JSON.stringify(res.json));

  res = await request("GET", "/characters", undefined, token);
  check(res.status === 200 && res.json?.characters?.length === 1, "the deleted character is gone");

  res = await request("DELETE", `/characters/${characterId}`, undefined, otherToken);
  check(res.status === 404, "characters of another account cannot be deleted");

  const thirdName = `Third${suffix}`.slice(0, 20);
  res = await request("POST", "/characters", { name: thirdName, class: "Mage", data: defaultCharacterData(thirdName, "Mage") }, token);
  check(res.status === 201, "a character can be created again after a deletion");

  const fourthName = `Fourth${suffix}`.slice(0, 20);
  res = await request("POST", "/characters", { name: fourthName, class: "Mage", data: defaultCharacterData(fourthName, "Mage") }, token);
  check(res.status === 409, "the per-account character limit is enforced", String(res.status));

  res = await request("POST", "/login", { username, password });
  check(res.status === 200, "login still allowed under the limit");
  let limited = false;
  for (let attempt = 0; attempt < 4; attempt += 1) {
    res = await request("POST", "/login", { username, password });
    if (res.status === 429) {
      limited = true;
      break;
    }
  }
  check(limited, "login rate limit kicks in", String(res.status));
} catch (error) {
  failures += 1;
  console.error("FATAL:", error);
  if (serverLog) console.error(serverLog);
} finally {
  child.kill("SIGTERM");
  await new Promise((resolve) => setTimeout(resolve, 300));
  try {
    fs.rmSync(tempDir, { recursive: true, force: true });
  } catch {
    // best effort cleanup
  }
  console.log(`\nCHECKS COMPLETE: ${checks - failures}/${checks} passed`);
  process.exit(failures === 0 ? 0 : 1);
}
