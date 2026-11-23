import { WebSocketServer, WebSocket } from "ws";

const clients = new Map();
const stages = new Map();

/** Check if an account is currently connected to the game server. */
export function isAccountOnline(accountName) {
  if (!accountName) return false;
  const target = String(accountName).trim().toLowerCase();
  for (const client of clients.values()) {
    if (client.account_name && client.account_name.trim().toLowerCase() === target) {
      if (client.ws && client.ws.readyState === WebSocket.OPEN) {
        return true;
      }
    }
  }
  return false;
}

/** Check if a character is currently active in the world. */
export function isCharacterOnline(characterName) {
  if (!characterName) return false;
  const target = String(characterName).trim().toLowerCase();
  for (const client of clients.values()) {
    if (client.name && client.name.trim().toLowerCase() === target) {
      if (client.ws && client.ws.readyState === WebSocket.OPEN) {
        return true;
      }
    }
  }
  return false;
}

/**
 * Stage-based multiplayer WebSocket relay.
 *
 * Handles stage sync, direct trading, and player street stalls.
 */
export function setupWsRelay(server) {
  const wss = new WebSocketServer({ server, path: "/ws" });

  let nextId = 1;

  function sendTo(targetId, message) {
    const target = clients.get(targetId);
    if (target && target.ws.readyState === WebSocket.OPEN) {
      target.ws.send(JSON.stringify(message));
    }
  }

  function broadcastToStage(stageNum, message, excludeId = null) {
    const room = stages.get(stageNum);
    if (!room) return;
    const json = JSON.stringify(message);
    for (const id of room) {
      if (id === excludeId) continue;
      const client = clients.get(id);
      if (client && client.ws.readyState === WebSocket.OPEN) {
        client.ws.send(json);
      }
    }
  }

  function removeFromStage(client) {
    if (client.stage === null) return;
    const room = stages.get(client.stage);
    if (room) {
      room.delete(client.id);
      if (room.size === 0) stages.delete(client.stage);
    }
    broadcastToStage(client.stage, {
      type: "player_left",
      id: client.id,
    });
    client.stage = null;
    client.stall = null;
  }

  const heartbeat = setInterval(() => {
    for (const [id, client] of clients) {
      if (client.isAlive === false) {
        removeFromStage(client);
        try {
          client.ws.terminate();
        } catch {}
        clients.delete(id);
        continue;
      }
      client.isAlive = false;
      try {
        client.ws.ping();
      } catch {}
    }
  }, 30000);

  wss.on("close", () => {
    clearInterval(heartbeat);
  });

  wss.on("connection", (ws) => {
    const id = nextId++;
    const client = {
      id,
      ws,
      isAlive: true,
      stage: null,
      name: "",
      class: "Warrior",
      level: 1,
      equipment: {},
      pos: [0, 0],
      vel: [0, 0],
      facing: 1.0,
      stall: null, // { title, items: [{name, price, qty}] }
    };
    clients.set(id, client);

    ws.on("pong", () => {
      client.isAlive = true;
    });

    ws.send(JSON.stringify({ type: "welcome", id }));

    ws.on("message", (raw) => {
      let data = null;
      try {
        data = JSON.parse(raw.toString("utf8"));
      } catch {
        return;
      }
      if (!data || typeof data.type !== "string") return;

      switch (data.type) {
        case "join_stage": {
          const stageNum = Number(data.stage) || 1;
          const charName = String(data.name || "Hero").slice(0, 32).trim();
          const acctName = String(data.account_name || "").slice(0, 32).trim();

          // Reject duplicate connection if already active on another client
          for (const [otherId, other] of clients) {
            if (otherId === id) continue;
            if (!other.ws || other.ws.readyState !== WebSocket.OPEN) continue;

            const sameAcct = Boolean(acctName && other.account_name && other.account_name.toLowerCase() === acctName.toLowerCase());
            const sameChar = Boolean(charName && other.name && other.name.toLowerCase() === charName.toLowerCase());

            if (sameAcct || sameChar) {
              ws.send(JSON.stringify({
                type: "error",
                error: "This account is already logged in on another device.",
              }));
              ws.close(4001, "Already logged in on another device");
              return;
            }
          }

          removeFromStage(client);

          client.stage = stageNum;
          client.name = charName || "Hero";
          client.account_name = acctName;
          client.class = String(data.class || "Warrior");
          client.level = Number(data.level) || 1;
          client.equipment = data.equipment || {};
          client.pos = Array.isArray(data.pos) ? data.pos : [200, 476];

          if (!stages.has(stageNum)) {
            stages.set(stageNum, new Set());
          }
          stages.get(stageNum).add(id);

          const others = [];
          for (const otherId of stages.get(stageNum)) {
            if (otherId === id) continue;
            const other = clients.get(otherId);
            if (other) {
              others.push({
                id: other.id,
                name: other.name,
                class: other.class,
                level: other.level,
                equipment: other.equipment,
                pos: other.pos,
                vel: other.vel,
                facing: other.facing,
                stall: other.stall,
              });
            }
          }

          ws.send(JSON.stringify({
            type: "stage_players",
            stage: stageNum,
            players: others,
          }));

          broadcastToStage(stageNum, {
            type: "player_joined",
            id: client.id,
            name: client.name,
            class: client.class,
            level: client.level,
            equipment: client.equipment,
            pos: client.pos,
            stall: client.stall,
          }, id);
          break;
        }

        case "move": {
          if (client.stage === null) return;
          if (Array.isArray(data.pos)) client.pos = data.pos;
          if (Array.isArray(data.vel)) client.vel = data.vel;
          if (typeof data.facing === "number") client.facing = data.facing;

          broadcastToStage(client.stage, {
            type: "player_moved",
            id: client.id,
            pos: client.pos,
            vel: client.vel,
            facing: client.facing,
            swing: Boolean(data.swing),
          }, id);
          break;
        }

        case "leave_stage": {
          removeFromStage(client);
          break;
        }

        case "chat": {
          // Stage chat — only players in the same stage
          if (client.stage === null) return;
          const text = String(data.text || "").trim().slice(0, 140);
          if (!text) return;
          broadcastToStage(client.stage, {
            type: "chat",
            channel: "stage",
            id: client.id,
            name: client.name,
            text,
          });
          break;
        }

        case "global_chat": {
          // Global chat — every connected client
          const text = String(data.text || "").trim().slice(0, 140);
          if (!text) return;
          const msg = JSON.stringify({
            type: "chat",
            channel: "global",
            id: client.id,
            name: client.name,
            text,
          });
          for (const [, c] of clients) {
            if (c.ws.readyState === WebSocket.OPEN) {
              c.ws.send(msg);
            }
          }
          break;
        }

        case "whisper": {
          // Whisper — private message to a named player
          const target = String(data.target || "").trim();
          const text = String(data.text || "").trim().slice(0, 140);
          if (!target || !text) return;
          // Find target by name or account name (case-insensitive)
          const targetLower = target.toLowerCase();
          const targetClient = [...clients.values()].find(
            (c) => c.name.toLowerCase() === targetLower ||
                   (c.account_name && c.account_name.toLowerCase() === targetLower)
          );
          if (!targetClient) {
            ws.send(JSON.stringify({
              type: "chat",
              channel: "whisper",
              id: client.id,
              name: "System",
              text: `Player "${target}" is not online.`,
              whisper_to: client.name,
            }));
            return;
          }
          // Send to recipient
          targetClient.ws.send(JSON.stringify({
            type: "chat",
            channel: "whisper",
            id: client.id,
            name: client.name,
            text,
            whisper_to: targetClient.name,
          }));
          // Echo back to sender so they see their own whisper
          ws.send(JSON.stringify({
            type: "chat",
            channel: "whisper",
            id: client.id,
            name: client.name,
            text,
            whisper_to: targetClient.name,
          }));
          break;
        }

        // --- Direct Player-to-Player Trading ---
        case "trade_request": {
          const targetId = Number(data.target_id);
          sendTo(targetId, {
            type: "trade_request",
            from_id: client.id,
            from_name: client.name,
          });
          break;
        }

        case "trade_response": {
          const targetId = Number(data.target_id);
          const accepted = Boolean(data.accepted);
          sendTo(targetId, {
            type: "trade_response",
            from_id: client.id,
            from_name: client.name,
            accepted,
          });
          break;
        }

        case "trade_offer": {
          const targetId = Number(data.target_id);
          sendTo(targetId, {
            type: "trade_offer",
            from_id: client.id,
            items: Array.isArray(data.items) ? data.items : [],
            gold: Math.max(0, Number(data.gold) || 0),
            locked: Boolean(data.locked),
          });
          break;
        }

        case "trade_confirm": {
          const targetId = Number(data.target_id);
          sendTo(targetId, {
            type: "trade_confirm",
            from_id: client.id,
          });
          break;
        }

        case "trade_cancel": {
          const targetId = Number(data.target_id);
          sendTo(targetId, {
            type: "trade_cancel",
            from_id: client.id,
          });
          break;
        }

        // --- Street Stalls / Player Shops ---
        case "stall_open": {
          if (client.stage === null) return;
          client.stall = {
            title: String(data.title || `${client.name}'s Shop`).slice(0, 32),
            items: Array.isArray(data.items) ? data.items.slice(0, 8) : [],
          };
          broadcastToStage(client.stage, {
            type: "player_stall_updated",
            id: client.id,
            stall: client.stall,
          });
          break;
        }

        case "stall_close": {
          if (client.stage === null) return;
          client.stall = null;
          broadcastToStage(client.stage, {
            type: "player_stall_updated",
            id: client.id,
            stall: null,
          });
          break;
        }

        case "stall_buy": {
          const sellerId = Number(data.seller_id);
          const seller = clients.get(sellerId);
          if (!seller || !seller.stall) {
            ws.send(JSON.stringify({ type: "stall_buy_result", success: false, error: "Stall is no longer open." }));
            return;
          }
          const itemName = String(data.item_name || "");
          const idx = seller.stall.items.findIndex((it) => it.name === itemName);
          if (idx === -1) {
            ws.send(JSON.stringify({ type: "stall_buy_result", success: false, error: "Item sold out." }));
            return;
          }
          const item = seller.stall.items[idx];
          // Remove from stall
          seller.stall.items.splice(idx, 1);

          // Tell buyer success
          ws.send(JSON.stringify({
            type: "stall_buy_result",
            success: true,
            seller_id: sellerId,
            item: item,
            price: item.price,
          }));

          // Tell seller item was purchased
          seller.ws.send(JSON.stringify({
            type: "stall_item_sold",
            buyer_id: client.id,
            buyer_name: client.name,
            item: item,
            price: item.price,
          }));

          // Broadcast updated stall
          broadcastToStage(client.stage, {
            type: "player_stall_updated",
            id: seller.id,
            stall: seller.stall,
          });
          break;
        }

        case "friend_notify": {
          // Real-time notification: a friend request was sent
          const targetName = String(data.target_name || "").trim().toLowerCase();
          for (const [cid, c] of clients) {
            const matches = c.name.toLowerCase() === targetName ||
                            (c.account_name && c.account_name.toLowerCase() === targetName);
            if (matches && c.ws.readyState === WebSocket.OPEN) {
              c.ws.send(JSON.stringify({
                type: "friend_notify",
                from_name: client.name,
                message: data.message || `${client.name} sent you a friend request!`,
              }));
              break;
            }
          }
          break;
        }
      }
    });

    ws.on("close", () => {
      removeFromStage(client);
      clients.delete(id);
    });

    ws.on("error", () => {
      removeFromStage(client);
      clients.delete(id);
    });
  });

  console.log("[server] Real-time multiplayer WebSocket relay ready on /ws");
  return wss;
}
