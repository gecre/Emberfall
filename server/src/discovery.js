import dgram from "node:dgram";
import os from "node:os";
import { DISCOVERY_PORT, PORT } from "./config.js";

/**
 * Lets a phone or an emulator find this server on the local network.
 *
 * The client sends "EMBERFALL_DISCOVER" to the broadcast address and to the
 * emulator's host alias; the server answers with the addresses it can be
 * reached on. No address has to be typed on the device.
 */

/** The addresses this server can be reached on, best guess first. */
export function localAddresses() {
  const interfaces = os.networkInterfaces();
  const addresses = [];
  for (const entries of Object.values(interfaces)) {
    for (const entry of entries || []) {
      if (entry.family !== "IPv4" || entry.internal) continue;
      addresses.push(entry.address);
    }
  }
  // Prefer the ranges a home network uses, they are the ones a phone shares.
  const rank = (address) => {
    if (address.startsWith("192.168.")) return 0;
    if (address.startsWith("10.")) return 1;
    if (/^172\.(1[6-9]|2\d|3[01])\./.test(address)) return 2;
    return 3;
  };
  addresses.sort((a, b) => rank(a) - rank(b));
  return [...new Set(addresses)];
}

/** The URLs a client can try, most likely first. */
export function baseUrls() {
  const urls = localAddresses().map(
    (address) => `http://${address}:${PORT}/api`,
  );
  urls.push(`http://127.0.0.1:${PORT}/api`);
  return urls;
}

/**
 * Starts the discovery responder.
 * @returns {import("node:dgram").Socket} the socket, so it can be closed
 */
export function startDiscovery() {
  const socket = dgram.createSocket({ type: "udp4", reuseAddr: true });

  socket.on("message", (message, remote) => {
    if (message.toString().trim() !== "EMBERFALL_DISCOVER") return;
    const payload = JSON.stringify({
      service: "emberfall-server",
      base_urls: baseUrls(),
    });
    console.log(`[discovery] answer for ${remote.address}:${remote.port}`);
    socket.send(payload, remote.port, remote.address, (error) => {
      if (error) console.error("[discovery] answer failed:", error.message);
    });
  });

  socket.on("error", (error) => {
    console.error("[discovery] socket error:", error.message);
  });

  socket.bind(DISCOVERY_PORT, () => {
    console.log(`[discovery] answering on udp ${DISCOVERY_PORT}`);
  });

  return socket;
}
