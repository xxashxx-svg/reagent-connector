// Reagent Connector — connects Roblox Studio to Reagent cloud AI
// Combined LuaLink server + bridge client in one process

import express from "express";
import fs from "fs";
import path from "path";
import crypto from "crypto";
import { EventEmitter } from "events";
import chokidar from "chokidar";
import WebSocket from "ws";

const VERSION = "1.0.0";
const PORT = 34872;
const BRIDGE_HEARTBEAT = 30000;
const STATUS_POLL = 5000;

// ---- config ----
const CONFIG_PATH = path.join(process.cwd(), "config.json");
let config = { token: "", server: "wss://reagent-server-small-shape-4547.fly.dev/bridge" };
try {
  if (fs.existsSync(CONFIG_PATH)) config = { ...config, ...JSON.parse(fs.readFileSync(CONFIG_PATH, "utf-8")) };
} catch {}

// CLI args override config
const args = Object.fromEntries(
  process.argv.slice(2).filter(a => a.startsWith("--")).map(a => { const [k, v] = a.slice(2).split("="); return [k, v || "true"]; })
);
if (args.token) config.token = args.token;
if (args.server) config.server = args.server;

// ---- project paths ----
const ROOT_DIR = process.cwd();
const PROJECTS_DIR = path.join(ROOT_DIR, "projects");

function sanitizeName(name) {
  return name.replace(/[\r\n]/g, "").replace(/[<>:"/\\|?*]/g, "_").trim();
}
function ensureDir(dir) { if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true }); }
function getProjectDir(name) { return path.join(PROJECTS_DIR, sanitizeName(name)); }
function getProjectSrcDir(name) { return path.join(getProjectDir(name), "src"); }
function getProjectFile(name) { return path.join(getProjectDir(name), "project.json"); }
function safeReadFile(p) { try { return fs.readFileSync(p, "utf-8"); } catch { return ""; } }
function listProjects() {
  if (!fs.existsSync(PROJECTS_DIR)) return [];
  return fs.readdirSync(PROJECTS_DIR).filter(n => fs.statSync(path.join(PROJECTS_DIR, n)).isDirectory()).map(n => ({ name: n, active: true }));
}

// ---- state ----
let currentProject = null;
const connectedStudios = new Map();
const watchersByProject = new Map();
const syncingProjects = new Set();
const pendingChangesByProject = new Map();
const lastSyncByProject = new Map();
const mcpCommandsByProject = new Map();
const mcpCommandEmitter = new EventEmitter();
const mcpConnectedProjects = new Set();

function getPendingChanges(name) {
  if (!pendingChangesByProject.has(name)) pendingChangesByProject.set(name, new Map());
  return pendingChangesByProject.get(name);
}
function getLastSync(name) { return lastSyncByProject.get(name) || 0; }
function setLastSync(name) { lastSyncByProject.set(name, Date.now()); }
function getActiveProjects() { return Array.from(watchersByProject.keys()); }
function getMcpCommands(name) {
  if (!mcpCommandsByProject.has(name)) mcpCommandsByProject.set(name, []);
  return mcpCommandsByProject.get(name);
}

// ---- project setup ----
function ensureProjectSetup(name) {
  const safe = sanitizeName(name || "DefaultProject");
  const srcDir = getProjectSrcDir(safe);
  ensureDir(srcDir);
  for (const d of ["ServerScriptService", "ReplicatedStorage", "StarterPlayer/StarterPlayerScripts", "StarterPlayer/StarterCharacterScripts", "StarterGui", "ServerStorage", "Workspace"]) {
    ensureDir(path.join(srcDir, d));
  }
  const pf = getProjectFile(safe);
  if (!fs.existsSync(pf)) fs.writeFileSync(pf, JSON.stringify({ name: safe, version: 2, tree: {} }, null, 2));
  return { srcDir, name: safe };
}

// ---- file watcher ----
function setupProjectWatcher(name) {
  const safe = sanitizeName(name);
  if (watchersByProject.has(safe)) return;
  const srcDir = getProjectSrcDir(safe);
  ensureDir(srcDir);

  const watcher = chokidar.watch(srcDir, {
    ignored: /(^|[\/\\])\../, persistent: true, ignoreInitial: true,
    awaitWriteFinish: { stabilityThreshold: 100, pollInterval: 50 }
  });

  const handleChange = (filePath, eventType) => {
    if (Date.now() - getLastSync(safe) < 3000) return;
    if (!filePath.endsWith(".lua")) return;
    const rel = path.relative(srcDir, filePath).replace(/\\/g, "/");
    let source = "";
    if (eventType !== "unlink" && fs.existsSync(filePath)) source = safeReadFile(filePath);
    getPendingChanges(safe).set(rel, { type: eventType, path: rel, source, timestamp: Date.now() });
    console.log(`  [${safe}] File ${eventType}: ${rel}`);
  };

  watcher.on("change", p => handleChange(p, "change"));
  watcher.on("add", p => handleChange(p, "add"));
  watcher.on("unlink", p => handleChange(p, "unlink"));
  watcher.on("error", err => console.error(`  [${safe}] Watcher error:`, err));
  watchersByProject.set(safe, watcher);
  console.log(`  Watching ${srcDir}`);
}

// ---- MCP command queue ----
function queueMcpCommand(project, type, params) {
  return new Promise((resolve, reject) => {
    const id = crypto.randomUUID();
    const commands = getMcpCommands(project);
    commands.push({ id, type, params, resolve, reject, created: Date.now() });
    mcpCommandEmitter.emit("commands:" + project);
    setTimeout(() => {
      const idx = commands.findIndex(c => c.id === id);
      if (idx !== -1) { commands.splice(idx, 1); reject(new Error("Command timed out")); }
    }, 30000);
  });
}

// ---- plugin auto-install ----
function installPlugin() {
  const localPlugin = path.join(ROOT_DIR, "plugin", "ReagentConnector.lua");
  if (!fs.existsSync(localPlugin)) return;
  let pluginsDir;
  if (process.platform === "darwin") {
    pluginsDir = path.join(process.env.HOME || "", "Documents", "Roblox", "Plugins");
  } else {
    pluginsDir = path.join(process.env.LOCALAPPDATA || "", "Roblox", "Plugins");
  }
  try {
    ensureDir(pluginsDir);
    fs.copyFileSync(localPlugin, path.join(pluginsDir, "ReagentConnector.lua"));
    console.log("  Plugin installed to Roblox Plugins folder");
  } catch (err) {
    console.log("  Could not install plugin:", err.message);
  }
}

// ---- Express server ----
const app = express();
app.use(express.json({ limit: "50mb" }));

// CORS
app.use((_, res, next) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");
  if (_.method === "OPTIONS") return res.sendStatus(200);
  next();
});

// health
app.get("/ping", (_, res) => {
  let pending = 0;
  for (const c of pendingChangesByProject.values()) pending += c.size;
  res.json({
    status: "ok", name: "Reagent Connector", version: VERSION,
    pendingChanges: pending, activeProjects: getActiveProjects(),
    syncingProjects: Array.from(syncingProjects), connectedStudios: connectedStudios.size,
    mcpConnectedProjects: Array.from(mcpConnectedProjects), projects: listProjects(),
  });
});

// studio connect
app.post("/studio-connect", (req, res) => {
  const { project, placeId, placeName } = req.body;
  connectedStudios.set(placeId || Date.now(), { project: project || "Unknown", placeName: placeName || "Unknown", connectedAt: new Date().toISOString() });
  console.log(`\n  Studio connected: ${project || "Unknown"} (${placeName || "Unknown"})\n`);
  res.json({ status: "ok", message: "Connected", connectedStudios: connectedStudios.size });
});

app.post("/studio-disconnect", (req, res) => {
  const { placeId } = req.body;
  if (placeId) connectedStudios.delete(placeId);
  res.json({ status: "ok" });
});

// sync from Studio
app.post("/sync", (req, res) => {
  const data = req.body;
  if (!data || (!data.tree && !data.scripts)) return res.status(400).json({ error: "Invalid sync data" });
  const name = sanitizeName(data.name || data.projectName || "DefaultProject");
  if (syncingProjects.has(name)) return res.status(429).json({ error: "Already syncing" });

  syncingProjects.add(name);
  res.json({ success: true, message: "Sync started", project: name });

  setImmediate(async () => {
    try {
      const { srcDir } = ensureProjectSetup(name);
      currentProject = name;

      // write scripts
      const scripts = data.scripts || extractScripts(data.tree, "");
      let count = 0;
      for (const s of scripts) {
        const ext = s.type === "Script" ? ".server.lua" : s.type === "LocalScript" ? ".client.lua" : ".module.lua";
        const filePath = path.join(srcDir, s.path + ext);
        ensureDir(path.dirname(filePath));
        fs.writeFileSync(filePath, s.source || "");
        count++;
      }

      // save project.json
      if (data.tree) {
        fs.writeFileSync(getProjectFile(name), JSON.stringify({ name, version: 2, tree: data.tree }, null, 2));
      }

      setLastSync(name);
      setupProjectWatcher(name);
      console.log(`  Synced ${count} scripts for ${name}`);
    } catch (err) {
      console.error("  Sync error:", err.message);
    } finally {
      syncingProjects.delete(name);
    }
  });
});

function extractScripts(tree, parentPath) {
  const scripts = [];
  const scriptClasses = { Script: true, LocalScript: true, ModuleScript: true };
  function walk(node, currentPath) {
    if (!node || typeof node !== "object") return;
    for (const [key, child] of Object.entries(node)) {
      if (key.startsWith("$")) continue;
      const childPath = currentPath ? `${currentPath}/${key}` : key;
      if (child && child.$className && scriptClasses[child.$className] && child.$source !== undefined) {
        scripts.push({ path: childPath, type: child.$className, source: child.$source });
      }
      if (child && typeof child === "object") walk(child, childPath);
    }
  }
  walk(tree, parentPath);
  return scripts;
}

// get pending file changes
app.get("/changes", (req, res) => {
  const name = sanitizeName(req.query.project || "");
  if (!name) return res.status(400).json({ error: "Missing project" });
  const changes = Array.from(getPendingChanges(name).values());
  getPendingChanges(name).clear();
  res.json({ changes, count: changes.length, project: name });
});

// sync progress (stub)
app.get("/sync-progress", (_, res) => res.json({ progress: 100, status: "done" }));

// ---- MCP endpoints (called by bridge → Fly → AI) ----

// plugin polls for commands
app.get("/mcp/commands", (req, res) => {
  const name = sanitizeName(req.query.project || "");
  if (!name) return res.status(400).json({ error: "Missing project" });
  mcpConnectedProjects.add(name);

  const commands = getMcpCommands(name).map(c => ({ id: c.id, type: c.type, params: c.params }));
  if (commands.length > 0) return res.json({ commands });

  // long poll up to 15s
  let done = false;
  const onCmd = () => { if (done) return; done = true; clearTimeout(t); res.json({ commands: getMcpCommands(name).map(c => ({ id: c.id, type: c.type, params: c.params })) }); };
  const t = setTimeout(() => { if (done) return; done = true; mcpCommandEmitter.removeListener("commands:" + name, onCmd); res.json({ commands: [] }); }, 15000);
  mcpCommandEmitter.once("commands:" + name, onCmd);
  req.on("close", () => { if (!done) { done = true; clearTimeout(t); mcpCommandEmitter.removeListener("commands:" + name, onCmd); } });
});

// plugin returns command result
app.post("/mcp/command-result", (req, res) => {
  const { project, commandId, result, error } = req.body;
  if (!project || !commandId) return res.status(400).json({ error: "Missing params" });
  const commands = getMcpCommands(sanitizeName(project));
  const idx = commands.findIndex(c => c.id === commandId);
  if (idx !== -1) {
    const cmd = commands[idx];
    commands.splice(idx, 1);
    if (error) cmd.reject(new Error(error)); else cmd.resolve(result);
  }
  res.json({ ok: true });
});

// MCP tool endpoints — these queue commands for the plugin to execute
app.get("/mcp/get-instance", async (req, res) => {
  try { res.json(await queueMcpCommand(sanitizeName(req.query.project), "get-instance", { path: req.query.path })); }
  catch (e) { res.json({ error: e.message }); }
});

app.get("/mcp/get-children", async (req, res) => {
  try { res.json(await queueMcpCommand(sanitizeName(req.query.project), "get-children", { path: req.query.path })); }
  catch (e) { res.json({ error: e.message }); }
});

app.get("/mcp/find-instances", async (req, res) => {
  try { res.json(await queueMcpCommand(sanitizeName(req.query.project), "find-instances", { className: req.query.className, name: req.query.name })); }
  catch (e) { res.json({ error: e.message }); }
});

app.post("/mcp/create-instance", async (req, res) => {
  try { res.json(await queueMcpCommand(sanitizeName(req.body.project), "create-instance", req.body)); }
  catch (e) { res.json({ error: e.message }); }
});

app.post("/mcp/modify-instance", async (req, res) => {
  try { res.json(await queueMcpCommand(sanitizeName(req.body.project), "modify-instance", req.body)); }
  catch (e) { res.json({ error: e.message }); }
});

app.post("/mcp/delete-instance", async (req, res) => {
  try { res.json(await queueMcpCommand(sanitizeName(req.body.project), "delete-instance", req.body)); }
  catch (e) { res.json({ error: e.message }); }
});

app.post("/mcp/run-lua", async (req, res) => {
  try { res.json(await queueMcpCommand(sanitizeName(req.body.project), "run-lua", { code: req.body.code })); }
  catch (e) { res.json({ error: e.message }); }
});

app.post("/mcp/clone-instance", async (req, res) => {
  try { res.json(await queueMcpCommand(sanitizeName(req.body.project), "clone-instance", req.body)); }
  catch (e) { res.json({ error: e.message }); }
});

app.post("/mcp/move-instance", async (req, res) => {
  try { res.json(await queueMcpCommand(sanitizeName(req.body.project), "move-instance", req.body)); }
  catch (e) { res.json({ error: e.message }); }
});

app.get("/mcp/get-selection", async (req, res) => {
  try { res.json(await queueMcpCommand(sanitizeName(req.query.project), "get-selection", {})); }
  catch (e) { res.json({ error: e.message }); }
});

app.get("/mcp/get-output", async (req, res) => {
  try { res.json(await queueMcpCommand(sanitizeName(req.query.project), "get-output", { type: req.query.type || "all" })); }
  catch (e) { res.json({ error: e.message }); }
});

// log storage for Studio output
const logsByProject = new Map();
app.post("/mcp/logs", (req, res) => {
  const { project, logs } = req.body;
  if (project && logs) {
    const safe = sanitizeName(project);
    if (!logsByProject.has(safe)) logsByProject.set(safe, []);
    const buf = logsByProject.get(safe);
    buf.push(...logs);
    while (buf.length > 500) buf.shift();
  }
  res.json({ ok: true });
});

// ---- Bridge client (connects to Fly.io) ----
let ws = null;
let hb = null;
let sp = null;
let lastStatus = "";

async function bridgeConnect() {
  if (!config.token) {
    console.log("  No bridge token set. Run with --token=YOUR_TOKEN or set it in config.json");
    return;
  }

  // verify license before connecting
  console.log(`  Verifying license...`);
  try {
    const verifyUrl = config.server.replace("wss://", "https://").replace("ws://", "http://").replace("/bridge", "");
    const vRes = await fetch(`${verifyUrl}/api/bridge/verify?token=${encodeURIComponent(config.token)}`);
    const vData = await vRes.json();
    if (vData.valid === false) {
      console.log(`\n  ACCESS DENIED: ${vData.reason}\n`);
      console.log("  Log in to reagent-ai.vercel.app and subscribe to a plan.\n");
      setTimeout(bridgeConnect, 30000); // retry in 30s in case they subscribe
      return;
    }
    console.log(`  License valid (${vData.plan} plan)`);
  } catch {
    // can't reach server — try connecting anyway (offline tolerance)
    console.log("  Could not verify license (server unreachable). Trying to connect...");
  }

  console.log(`  Connecting to Reagent cloud...`);
  ws = new WebSocket(config.server, { headers: { authorization: `Bearer ${config.token}` } });

  ws.on("open", async () => {
    console.log("  Connected to Reagent cloud!");
    const projects = getActiveProjects();
    ws.send(JSON.stringify({ type: "status", lualinkConnected: true, projects }));

    // heartbeat
    hb = setInterval(() => {
      if (ws?.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: "ping" }));
    }, BRIDGE_HEARTBEAT);

    // status poll — detect new projects within 5s
    sp = setInterval(() => {
      if (ws?.readyState !== WebSocket.OPEN) return;
      const projs = getActiveProjects();
      const connected = connectedStudios.size > 0;
      // also include projects from connectedStudios
      const allProjects = [...new Set([...projs, ...Array.from(connectedStudios.values()).map(s => s.project)])];
      const key = `${connected}:${allProjects.sort().join(",")}`;
      if (key !== lastStatus) {
        lastStatus = key;
        ws.send(JSON.stringify({ type: "status", lualinkConnected: true, projects: allProjects }));
      }
    }, STATUS_POLL);
  });

  ws.on("message", async (data) => {
    try {
      const msg = JSON.parse(data.toString());
      if (msg.type === "tool_call") {
        const result = await execBridgeTool(msg.tool, msg.input);
        ws.send(JSON.stringify({ type: "tool_result", requestId: msg.requestId, result }));
      }
    } catch (err) { console.error("  Bridge error:", err.message); }
  });

  ws.on("close", (code, reason) => {
    if (hb) { clearInterval(hb); hb = null; }
    if (sp) { clearInterval(sp); sp = null; }
    lastStatus = "";
    const msg = reason?.toString() || "";
    if (code === 4002 || msg.includes("Another device")) {
      console.log("\n  WARNING: Another device connected with your token!");
      console.log("  If this wasn't you, regenerate your token at reagent-ai.vercel.app\n");
      console.log("  Retrying in 10s...");
      setTimeout(bridgeConnect, 10000);
    } else if (code === 4003) {
      console.log(`\n  ACCESS DENIED: ${msg}\n`);
      setTimeout(bridgeConnect, 30000);
    } else {
      console.log("  Disconnected from cloud. Reconnecting in 3s...");
      setTimeout(bridgeConnect, 3000);
    }
  });

  ws.on("error", (err) => console.error("  Bridge error:", err.message));
}

async function execBridgeTool(tool, input) {
  const routes = {
    lualink_status: { m: "GET", p: "/ping" },
    get_children: { m: "GET", p: `/mcp/get-children?project=${encodeURIComponent(input?.project || "")}&path=${encodeURIComponent(input?.path || "")}` },
    get_instance: { m: "GET", p: `/mcp/get-instance?project=${encodeURIComponent(input?.project || "")}&path=${encodeURIComponent(input?.path || "")}` },
    find_instances: { m: "GET", p: `/mcp/find-instances?project=${encodeURIComponent(input?.project || "")}&className=${encodeURIComponent(input?.className || "")}&name=${encodeURIComponent(input?.name || "")}` },
    create_instance: { m: "POST", p: "/mcp/create-instance" },
    batch_create: { m: "POST", p: "/mcp/create-instance" },
    modify_instance: { m: "POST", p: "/mcp/modify-instance" },
    delete_instance: { m: "POST", p: "/mcp/delete-instance" },
    run_lua: { m: "POST", p: "/mcp/run-lua" },
    clone_instance: { m: "POST", p: "/mcp/clone-instance" },
    move_instance: { m: "POST", p: "/mcp/move-instance" },
    get_errors: { m: "GET", p: `/mcp/get-output?project=${encodeURIComponent(input?.project || "")}&type=error` },
    get_output: { m: "GET", p: `/mcp/get-output?project=${encodeURIComponent(input?.project || "")}&type=${encodeURIComponent(input?.type || "all")}` },
    get_selection: { m: "GET", p: `/mcp/get-selection?project=${encodeURIComponent(input?.project || "")}` },
  };

  const route = routes[tool];
  if (!route) return { error: `Unknown tool: ${tool}` };

  try {
    const opts = { method: route.m };
    if (route.m === "POST") { opts.headers = { "Content-Type": "application/json" }; opts.body = JSON.stringify(input); }
    const res = await fetch(`http://localhost:${PORT}${route.p}`, opts);
    return await res.json();
  } catch (err) { return { error: err.message }; }
}

// ---- start ----
ensureDir(PROJECTS_DIR);
installPlugin();

app.listen(PORT, () => {
  console.log(`\n  Reagent Connector v${VERSION}`);
  console.log(`  Port: ${PORT}`);
  console.log(`  Projects: ${PROJECTS_DIR}\n`);
  bridgeConnect();
});

process.on("SIGINT", () => { ws?.close(); process.exit(0); });
