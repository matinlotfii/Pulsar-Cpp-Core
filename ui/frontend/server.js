import { execFile } from "node:child_process";
import { createReadStream, existsSync, readFileSync, statSync } from "node:fs";
import { createServer } from "node:http";
import { extname, join, normalize } from "node:path";
import { performance } from "node:perf_hooks";
import { fileURLToPath } from "node:url";

const port = Number(process.env.PORT || 4173);
const root = join(fileURLToPath(new URL(".", import.meta.url)), "dist");
const jsonContentType = "application/json; charset=utf-8";
const nmcliTimeoutMs = 15_000;
const connectTimeoutMs = 30_000;
const speedTestBytes = 8_000_000;
const nmcliCandidates = [
  process.env.PULSAR_NMCLI_PATH,
  "/snap/bin/network-manager.nmcli",
  "/usr/bin/nmcli",
  "nmcli"
].filter(Boolean);
let resolvedNmcliCommandPromise;
let activeWifiUsageKey = null;
const wifiUsageSessions = new Map();

const contentTypes = {
  ".css": "text/css; charset=utf-8",
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".map": "application/json; charset=utf-8",
  ".png": "image/png",
  ".svg": "image/svg+xml",
  ".webp": "image/webp"
};

function resolveFile(urlPath) {
  const cleanPath = normalize(decodeURIComponent(urlPath.split("?")[0])).replace(
    /^(\.\.[/\\])+/,
    ""
  );
  const requested = join(root, cleanPath === "/" ? "index.html" : cleanPath);

  if (existsSync(requested) && statSync(requested).isFile()) {
    return requested;
  }

  return join(root, "index.html");
}

function sendJson(response, statusCode, payload) {
  response.writeHead(statusCode, {
    "Content-Type": jsonContentType,
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff"
  });
  response.end(JSON.stringify(payload));
}

function sendError(response, statusCode, message) {
  sendJson(response, statusCode, { error: message });
}

function runCommand(command, args, timeout = nmcliTimeoutMs) {
  return new Promise((resolve, reject) => {
    execFile(
      command,
      args,
      {
        timeout,
        maxBuffer: 4 * 1024 * 1024
      },
      (error, stdout, stderr) => {
        if (error) {
          const detail = String(stderr || "").trim() || error.message;
          reject(new Error(detail));
          return;
        }
        resolve(String(stdout || ""));
      }
    );
  });
}

async function resolveNmcliCommand() {
  if (resolvedNmcliCommandPromise) {
    return resolvedNmcliCommandPromise;
  }

  resolvedNmcliCommandPromise = (async () => {
    for (const candidate of nmcliCandidates) {
      try {
        await runCommand(candidate, ["--version"], 5_000);
        return candidate;
      } catch {
        continue;
      }
    }

    throw new Error(
      "No compatible nmcli command was found. On Ubuntu Core, connect the snap to NetworkManager or set PULSAR_NMCLI_PATH."
    );
  })();

  return resolvedNmcliCommandPromise;
}

async function runNmcli(args, timeout = nmcliTimeoutMs) {
  const nmcliCommand = await resolveNmcliCommand();
  return runCommand(nmcliCommand, args, timeout);
}

function splitNmcliFields(line) {
  const parts = [];
  let current = "";
  let escaping = false;

  for (const character of line) {
    if (escaping) {
      current += character;
      escaping = false;
      continue;
    }

    if (character === "\\") {
      escaping = true;
      continue;
    }

    if (character === ":") {
      parts.push(current);
      current = "";
      continue;
    }

    current += character;
  }

  parts.push(current);
  return parts.map((part) => part.trim());
}

function normalizeSecurity(value) {
  return value && value !== "--" ? value : "";
}

function normalizeSsid(value, fallback = "Hidden network") {
  return value && value.length > 0 ? value : fallback;
}

function toSignalNumber(value) {
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) ? Math.max(0, Math.min(100, parsed)) : 0;
}

function parseNmcliKeyValueOutput(output) {
  return output
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .reduce((entries, line) => {
      const separatorIndex = line.indexOf(":");
      if (separatorIndex === -1) {
        return entries;
      }

      entries.push({
        key: line.slice(0, separatorIndex),
        value: line.slice(separatorIndex + 1).trim()
      });
      return entries;
    }, []);
}

async function getWifiConnectionDetails(deviceName) {
  const output = await runNmcli([
    "-t",
    "-f",
    "GENERAL.CONNECTION,IP4.ADDRESS,IP4.GATEWAY,IP4.DNS,IP6.ADDRESS,IP6.GATEWAY,IP6.DNS",
    "device",
    "show",
    deviceName
  ]);

  const entries = parseNmcliKeyValueOutput(output);
  const ipv4 = entries
    .filter((entry) => entry.key.startsWith("IP4.ADDRESS"))
    .map((entry) => entry.value)
    .filter(Boolean);
  const ipv6 = entries
    .filter((entry) => entry.key.startsWith("IP6.ADDRESS"))
    .map((entry) => entry.value)
    .filter(Boolean);
  const dns = entries
    .filter((entry) => entry.key.startsWith("IP4.DNS") || entry.key.startsWith("IP6.DNS"))
    .map((entry) => entry.value)
    .filter(Boolean);

  return {
    connection: entries.find((entry) => entry.key === "GENERAL.CONNECTION")?.value || "",
    ipv4,
    ipv6,
    dns,
    gateway4: entries.find((entry) => entry.key === "IP4.GATEWAY")?.value || "",
    gateway6: entries.find((entry) => entry.key === "IP6.GATEWAY")?.value || "",
    password: await getSavedWifiPassword(entries.find((entry) => entry.key === "GENERAL.CONNECTION")?.value || "")
  };
}

async function getSavedWifiPassword(connectionName) {
  if (!connectionName) {
    return "";
  }

  try {
    const output = await runNmcli([
      "-s",
      "-g",
      "802-11-wireless-security.psk",
      "connection",
      "show",
      connectionName
    ]);
    return output.trim();
  } catch {
    return "";
  }
}

function readWifiStatistic(deviceName, statName) {
  try {
    const value = Number.parseInt(
      readFileSync(`/sys/class/net/${deviceName}/statistics/${statName}`, "utf-8").trim(),
      10
    );
    return Number.isFinite(value) ? value : 0;
  } catch {
    return 0;
  }
}

function getWifiUsage(deviceName, ssid) {
  const rxBytes = readWifiStatistic(deviceName, "rx_bytes");
  const txBytes = readWifiStatistic(deviceName, "tx_bytes");
  const totalBytes = rxBytes + txBytes;
  const usageKey = `${deviceName}:${ssid}`;

  if (activeWifiUsageKey !== usageKey || !wifiUsageSessions.has(usageKey)) {
    wifiUsageSessions.clear();
    wifiUsageSessions.set(usageKey, {
      connectedAt: new Date().toISOString(),
      baseTotalBytes: totalBytes,
      lastSessionBytes: 0,
      lastTotalBytes: totalBytes
    });
    activeWifiUsageKey = usageKey;
  }

  const session = wifiUsageSessions.get(usageKey);
  const stableTotalBytes = Math.max(totalBytes, session.lastTotalBytes);
  const stableSessionBytes = Math.max(0, stableTotalBytes - session.baseTotalBytes, session.lastSessionBytes);
  session.lastTotalBytes = stableTotalBytes;
  session.lastSessionBytes = stableSessionBytes;

  return {
    rxBytes,
    txBytes,
    totalBytes: stableTotalBytes,
    sessionBytes: stableSessionBytes,
    connectedAt: session.connectedAt
  };
}

async function getWifiDevice() {
  const output = await runNmcli([
    "-t",
    "-f",
    "DEVICE,TYPE,STATE,CONNECTION",
    "device",
    "status"
  ]);

  const devices = output
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => {
      const [device, type, state, connection] = splitNmcliFields(line);
      return {
        device,
        type,
        state,
        connection: connection || ""
      };
    });

  return devices.find((device) => device.type === "wifi") || null;
}

async function scanWifiNetworks(deviceName, { refresh = false } = {}) {
  if (refresh) {
    try {
      await runNmcli(["device", "wifi", "rescan", "ifname", deviceName], 10_000);
    } catch {
      // A rescan may fail while the adapter is busy. We still return the latest list.
    }
  }

  const output = await runNmcli([
    "-t",
    "-f",
    "IN-USE,SSID,BSSID,SIGNAL,SECURITY,CHAN,FREQ,RATE",
    "device",
    "wifi",
    "list",
    "ifname",
    deviceName
  ]);

  const deduped = new Map();
  let hiddenCount = 0;

  output
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .forEach((line) => {
      const [inUse, rawSsid, bssid, signal, security, channel, frequency, rate] = splitNmcliFields(line);
      const ssid = normalizeSsid(rawSsid, "");
      const signalValue = toSignalNumber(signal);
      const requiresPassword = normalizeSecurity(security).length > 0;
      const idBase = ssid || `hidden-${hiddenCount++}`;
      const key = ssid || bssid || idBase;
      const network = {
        id: key,
        ssid: normalizeSsid(rawSsid),
        bssid: bssid || "",
        signal: signalValue,
        security: normalizeSecurity(security),
        requiresPassword,
        isConnected: inUse === "*",
        channel: channel || "",
        frequency: frequency || "",
        rate: rate || ""
      };

      const existing = deduped.get(key);
      if (!existing || network.isConnected || network.signal > existing.signal) {
        deduped.set(key, network);
      }
    });

  return [...deduped.values()].sort((left, right) => {
    if (left.isConnected !== right.isConnected) {
      return left.isConnected ? -1 : 1;
    }
    return right.signal - left.signal;
  });
}

async function buildWifiSnapshot({ refresh = false } = {}) {
  const wifiDevice = await getWifiDevice();
  if (!wifiDevice) {
    activeWifiUsageKey = null;
    wifiUsageSessions.clear();
    return {
      available: false,
      device: null,
      state: "missing",
      connected: false,
      ssid: null,
      signal: 0,
      security: "",
      details: null,
      usage: null,
      networks: []
    };
  }

  const networks = await scanWifiNetworks(wifiDevice.device, { refresh });
  const activeNetwork =
    networks.find((network) => network.isConnected) ||
    (wifiDevice.connection
      ? {
          id: wifiDevice.connection,
          ssid: wifiDevice.connection,
          bssid: "",
          signal: 0,
          security: "",
          requiresPassword: false,
          isConnected: true,
          channel: "",
          frequency: "",
          rate: ""
        }
      : null);
  const details = activeNetwork?.ssid ? await getWifiConnectionDetails(wifiDevice.device) : null;
  const usage = activeNetwork?.ssid ? getWifiUsage(wifiDevice.device, activeNetwork.ssid) : null;

  if (!activeNetwork?.ssid) {
    activeWifiUsageKey = null;
    wifiUsageSessions.clear();
  }

  return {
    available: true,
    device: wifiDevice.device,
    state: wifiDevice.state,
    connected: Boolean(activeNetwork && activeNetwork.ssid),
    ssid: activeNetwork?.ssid || null,
    signal: activeNetwork?.signal || 0,
    security: activeNetwork?.security || "",
    details,
    usage,
    networks
  };
}

async function readJsonBody(request) {
  const chunks = [];

  for await (const chunk of request) {
    chunks.push(chunk);
  }

  if (chunks.length === 0) {
    return {};
  }

  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf-8"));
  } catch {
    throw new Error("Invalid JSON body");
  }
}

async function connectWifi(ssid, password = "") {
  const wifiDevice = await getWifiDevice();
  if (!wifiDevice) {
    throw new Error("No Wi-Fi adapter was detected.");
  }

  const args = ["device", "wifi", "connect", ssid, "ifname", wifiDevice.device];
  if (password) {
    args.push("password", password);
  }

  await runNmcli(args, connectTimeoutMs);
  return buildWifiSnapshot({ refresh: true });
}

async function disconnectWifi() {
  const wifiDevice = await getWifiDevice();
  if (!wifiDevice) {
    throw new Error("No Wi-Fi adapter was detected.");
  }

  if (!wifiDevice.connection) {
    return buildWifiSnapshot({ refresh: true });
  }

  await runNmcli(["device", "disconnect", wifiDevice.device], connectTimeoutMs);
  return buildWifiSnapshot({ refresh: true });
}

async function runSpeedTest() {
  const snapshot = await buildWifiSnapshot();
  if (!snapshot.connected) {
    throw new Error("Connect to a Wi-Fi network before running the speed test.");
  }

  const latencyOutput = await runCommand(
    "curl",
    [
      "-L",
      "-o",
      "/dev/null",
      "-sS",
      "-w",
      "%{time_starttransfer}",
      "https://www.google.com/generate_204"
    ],
    20_000
  );
  const latencySeconds = Number.parseFloat(latencyOutput.trim());
  if (!Number.isFinite(latencySeconds)) {
    throw new Error("Latency probe failed.");
  }

  const speedOutput = await runCommand(
    "curl",
    [
      "-L",
      "-o",
      "/dev/null",
      "-sS",
      "-w",
      "%{time_total} %{speed_download} %{size_download}",
      `https://speed.cloudflare.com/__down?bytes=${speedTestBytes}`
    ],
    45_000
  );
  const [timeTotalRaw, speedDownloadRaw, sizeDownloadRaw] = speedOutput.trim().split(/\s+/);
  const seconds = Number.parseFloat(timeTotalRaw);
  const bytesPerSecond = Number.parseFloat(speedDownloadRaw);
  const bytesRead = Number.parseInt(sizeDownloadRaw, 10);
  if (!Number.isFinite(seconds) || !Number.isFinite(bytesPerSecond) || !Number.isFinite(bytesRead)) {
    throw new Error("Download speed test failed.");
  }

  return {
    latencyMs: Math.round(latencySeconds * 1000),
    downloadMbps: Number(((bytesPerSecond * 8) / 1_000_000).toFixed(1)),
    transferredBytes: bytesRead,
    measuredAt: new Date().toISOString(),
    source: "speed.cloudflare.com"
  };
}

async function handleApiRequest(request, response, requestUrl) {
  if (requestUrl.pathname === "/api/wifi/status" && request.method === "GET") {
    const refresh = requestUrl.searchParams.get("refresh") === "1";
    const snapshot = await buildWifiSnapshot({ refresh });
    sendJson(response, 200, snapshot);
    return true;
  }

  if (requestUrl.pathname === "/api/wifi/connect" && request.method === "POST") {
    const body = await readJsonBody(request);
    const ssid = typeof body.ssid === "string" ? body.ssid.trim() : "";
    const password = typeof body.password === "string" ? body.password : "";

    if (!ssid) {
      sendError(response, 400, "Wi-Fi name is required.");
      return true;
    }

    const snapshot = await connectWifi(ssid, password);
    sendJson(response, 200, snapshot);
    return true;
  }

  if (requestUrl.pathname === "/api/wifi/disconnect" && request.method === "POST") {
    const snapshot = await disconnectWifi();
    sendJson(response, 200, snapshot);
    return true;
  }

  if (requestUrl.pathname === "/api/wifi/speedtest" && request.method === "POST") {
    const result = await runSpeedTest();
    sendJson(response, 200, result);
    return true;
  }

  if (requestUrl.pathname.startsWith("/api/")) {
    sendError(response, 404, "API route not found.");
    return true;
  }

  return false;
}

createServer(async (request, response) => {
  const requestUrl = new URL(request.url || "/", `http://${request.headers.host || "localhost"}`);

  try {
    if (await handleApiRequest(request, response, requestUrl)) {
      return;
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unexpected server error.";
    sendError(response, 500, message);
    return;
  }

  const filePath = resolveFile(request.url || "/");
  const extension = extname(filePath);

  response.writeHead(200, {
    "Content-Type": contentTypes[extension] || "application/octet-stream",
    "Cache-Control":
      extension === ".html" ? "no-store" : "public, max-age=31536000, immutable",
    "X-Content-Type-Options": "nosniff"
  });

  createReadStream(filePath).pipe(response);
}).listen(port, "0.0.0.0", () => {
  console.log(`Surgery MaxVision HMI serving http://localhost:${port}`);
});
