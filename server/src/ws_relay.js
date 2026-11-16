import { WebSocketServer, WebSocket } from "ws";

/**
 * Stage-based multiplayer WebSocket relay.
 *
 * Players in the same stage receive each other's join, move, swing, and leave events.
 */
export function setupWsRelay(server) {
  const wss = new WebSocketServer({ server, path: "/ws" });

  // Map of client_id -> client data
  const clients = new Map();
  // Map of stage_number -> Set of client_id
  const stages = new Map();

  let nextId = 1;

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
  }

  wss.on("connection", (ws, req) => {
    const id = nextId++;
    const client = {
      id,
      ws,
      stage: null,
      name: "",
      class: "Warrior",
      level: 1,
      equipment: {},
      pos: [0, 0],
      vel: [0, 0],
      facing: 1.0,
    };
    clients.set(id, client);

    // Tell the client its assigned peer ID
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
          removeFromStage(client);

          client.stage = stageNum;
          client.name = String(data.name || "Hero").slice(0, 32);
          client.class = String(data.class || "Warrior");
          client.level = Number(data.level) || 1;
          client.equipment = data.equipment || {};
          client.pos = Array.isArray(data.pos) ? data.pos : [200, 476];

          if (!stages.has(stageNum)) {
            stages.set(stageNum, new Set());
          }
          stages.get(stageNum).add(id);

          // Collect other players currently in this stage
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
              });
            }
          }

          // Send existing players to the joining player
          ws.send(JSON.stringify({
            type: "stage_players",
            stage: stageNum,
            players: others,
          }));

          // Notify existing players in this stage of the new arrival
          broadcastToStage(stageNum, {
            type: "player_joined",
            id: client.id,
            name: client.name,
            class: client.class,
            level: client.level,
            equipment: client.equipment,
            pos: client.pos,
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
          if (client.stage === null) return;
          const text = String(data.text || "").trim().slice(0, 140);
          if (!text) return;
          broadcastToStage(client.stage, {
            type: "chat",
            id: client.id,
            name: client.name,
            text,
          });
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
