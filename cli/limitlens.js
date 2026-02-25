#!/usr/bin/env node

"use strict";

/*
This file is the terminal-native entrypoint for LimitLens. It reads local provider artifacts,
normalizes them into one snapshot, and renders that snapshot either as human text or JSON.

It exists as a separate file because the CLI is one of the two primary user interfaces in the
system and needs to stay executable without launching the macOS app. The file currently embeds
adapter, normalization, and rendering logic together for speed of iteration during the prototype
phase; later milestones will move shared logic into a core package.

This file talks to local provider outputs in `~/.codex`, `~/.claude`, and Antigravity log paths,
and it talks to the local `antigravity` binary for version introspection. It exports nothing and
acts as a process-level orchestrator that performs one snapshot cycle per invocation.
*/

const os = require("os");
const path = require("path");
const fs = require("fs/promises");
const cp = require("child_process");

const DEFAULTS = {
  codexSessionsPath: "~/.codex/sessions",
  claudeProjectsPath: "~/.claude/projects",
  antigravityLogsPath: "~/Library/Application Support/Antigravity/logs",
  intervalSeconds: 60,
};

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    printHelp();
    process.exit(0);
  }

  // Watch mode keeps polling in-place so the terminal becomes a live monitor.
  if (args.watch) {
    await runOnce(args);
    const intervalMs = Math.max(10, args.intervalSeconds) * 1000;
    setInterval(() => {
      runOnce(args).catch((err) => {
        process.stderr.write(`${formatNow()} error: ${String(err && err.message ? err.message : err)}\n`);
      });
    }, intervalMs);
    return;
  }

  await runOnce(args);
}

async function runOnce(args) {
  const snapshot = await collectSnapshot(args);
  if (args.json) {
    process.stdout.write(`${JSON.stringify(snapshot, null, 2)}\n`);
    return;
  }
  process.stdout.write(formatSnapshot(snapshot));
}

function parseArgs(argv) {
  const parsed = {
    help: false,
    json: false,
    watch: false,
    intervalSeconds: DEFAULTS.intervalSeconds,
    codexSessionsPath: DEFAULTS.codexSessionsPath,
    claudeProjectsPath: DEFAULTS.claudeProjectsPath,
    antigravityLogsPath: DEFAULTS.antigravityLogsPath,
  };

  // Parse a small explicit flag surface so CLI behavior stays predictable.
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "-h" || arg === "--help") {
      parsed.help = true;
    } else if (arg === "--json") {
      parsed.json = true;
    } else if (arg === "--watch") {
      parsed.watch = true;
    } else if (arg === "--interval") {
      parsed.intervalSeconds = Number(argv[i + 1]);
      i += 1;
    } else if (arg === "--codex-path") {
      parsed.codexSessionsPath = argv[i + 1];
      i += 1;
    } else if (arg === "--claude-path") {
      parsed.claudeProjectsPath = argv[i + 1];
      i += 1;
    } else if (arg === "--antigravity-logs-path") {
      parsed.antigravityLogsPath = argv[i + 1];
      i += 1;
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  // Guardrail for invalid intervals to keep watch mode sane.
  if (!Number.isFinite(parsed.intervalSeconds) || parsed.intervalSeconds <= 0) {
    parsed.intervalSeconds = DEFAULTS.intervalSeconds;
  }
  return parsed;
}

async function collectSnapshot(args) {
  const codexSessionsPath = expandHome(args.codexSessionsPath);
  const claudeProjectsPath = expandHome(args.claudeProjectsPath);
  const antigravityLogsPath = expandHome(args.antigravityLogsPath);

  // Providers are independent read paths, so we refresh them concurrently.
  const [codex, claude, antigravity] = await Promise.all([
    collectCodex(codexSessionsPath),
    collectClaude(claudeProjectsPath, antigravityLogsPath),
    collectAntigravity(antigravityLogsPath),
  ]);

  return {
    capturedAt: new Date().toISOString(),
    paths: {
      codexSessionsPath,
      claudeProjectsPath,
      antigravityLogsPath,
    },
    providers: {
      codex,
      claude,
      antigravity,
    },
  };
}

async function collectCodex(codexSessionsPath) {
  const latestJsonl = await findLatestFile(codexSessionsPath, (name) => name.endsWith(".jsonl"), 6000);
  if (!latestJsonl) {
    return {
      available: false,
      reason: "No Codex session JSONL files found.",
    };
  }

  const tail = await readFileTail(latestJsonl, 1024 * 1024);
  const lines = tail.split(/\r?\n/);
  let tokenCountPayload = null;
  // Walk backward because we care about the newest signal, not full history.
  for (let i = lines.length - 1; i >= 0; i -= 1) {
    const line = lines[i].trim();
    if (!line.startsWith("{")) {
      continue;
    }
    const parsed = tryParseJson(line);
    if (!parsed) {
      continue;
    }
    if (parsed.type === "event_msg" && parsed.payload && parsed.payload.type === "token_count") {
      tokenCountPayload = parsed.payload;
      break;
    }
  }

  if (!tokenCountPayload) {
    return {
      available: false,
      reason: "No Codex token_count event found in latest session file.",
      sourceFile: latestJsonl,
    };
  }

  const info = tokenCountPayload.info || {};
  const rateLimits = tokenCountPayload.rate_limits || {};
  return {
    available: true,
    sourceFile: latestJsonl,
    modelContextWindow: numberOrNull(info.model_context_window),
    totalTokenUsage: info.total_token_usage || null,
    lastTokenUsage: info.last_token_usage || null,
    rateLimits,
  };
}

async function collectClaude(claudeProjectsPath, antigravityLogsPath) {
  const latestJsonl = await findLatestFile(claudeProjectsPath, (name) => name.endsWith(".jsonl"), 8000);
  let usage = null;
  let fallbackUsage = null;
  if (latestJsonl) {
    const tail = await readFileTail(latestJsonl, 1024 * 1024);
    const lines = tail.split(/\r?\n/);
    // Prefer the most recent non-zero usage event, but keep a fallback if none exists.
    for (let i = lines.length - 1; i >= 0; i -= 1) {
      const line = lines[i].trim();
      if (!line.startsWith("{")) {
        continue;
      }
      const parsed = tryParseJson(line);
      const maybeUsage = parsed && parsed.message && parsed.message.usage;
      if (maybeUsage && typeof maybeUsage.input_tokens === "number") {
        if (!fallbackUsage) {
          fallbackUsage = maybeUsage;
        }
        const outputTokens = typeof maybeUsage.output_tokens === "number" ? maybeUsage.output_tokens : 0;
        if (maybeUsage.input_tokens > 0 || outputTokens > 0) {
          usage = maybeUsage;
          break;
        }
      }
    }
  }
  // Some sessions may end in non-content records; fallback preserves last known usage shape.
  if (!usage && fallbackUsage) {
    usage = fallbackUsage;
  }

  const claudeSettings = await readJsonIfExists(path.join(os.homedir(), ".claude.json"));
  const claudeAccount = claudeSettings && claudeSettings.oauthAccount ? claudeSettings.oauthAccount : null;

  const claudeVscodeLogPath = await getProviderLogFile(
    antigravityLogsPath,
    ["window1", "exthost", "Anthropic.claude-code", "Claude VSCode.log"],
  );
  let contextUsage = null;
  let lastRateLimit = null;
  if (claudeVscodeLogPath) {
    const tail = await readFileTail(claudeVscodeLogPath, 1024 * 1024);
    contextUsage = parseLastAutocompactUsage(tail);
    lastRateLimit = parseLastRateLimitEntry(tail);
  }

  return {
    available: Boolean(latestJsonl || claudeVscodeLogPath || claudeAccount),
    sourceFile: latestJsonl,
    latestUsage: usage,
    account: claudeAccount
      ? {
          emailAddress: claudeAccount.emailAddress || null,
          billingType: claudeAccount.billingType || null,
          hasExtraUsageEnabled: Boolean(claudeAccount.hasExtraUsageEnabled),
        }
      : null,
    vscodeLogFile: claudeVscodeLogPath,
    contextUsage,
    lastRateLimit,
  };
}

async function collectAntigravity(antigravityLogsPath) {
  const version = getAntigravityVersion();
  const codexLogPath = await getProviderLogFile(
    antigravityLogsPath,
    ["window1", "exthost", "openai.chatgpt", "Codex.log"],
  );

  let rateLimitSignal = null;
  if (codexLogPath) {
    const tail = await readFileTail(codexLogPath, 1024 * 1024);
    rateLimitSignal = parseLastRateLimitEntry(tail);
  }

  return {
    available: Boolean(version || codexLogPath),
    version,
    codexLogFile: codexLogPath,
    lastRateLimit: rateLimitSignal,
  };
}

function getAntigravityVersion() {
  try {
    const proc = cp.spawnSync("antigravity", ["--version"], {
      encoding: "utf8",
      timeout: 3000,
    });
    if (proc.error) {
      return null;
    }
    const lines = String(proc.stdout || "")
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean);
    if (lines.length === 0) {
      return null;
    }
    // The first line is the semantic version string we surface to users.
    return lines[0];
  } catch {
    return null;
  }
}

async function getProviderLogFile(logsRoot, pathParts) {
  const latestLogRoot = await getLatestTimestampedDirectory(logsRoot);
  if (!latestLogRoot) {
    return null;
  }
  const target = path.join(latestLogRoot, ...pathParts);
  try {
    await fs.access(target);
    return target;
  } catch {
    return null;
  }
}

async function getLatestTimestampedDirectory(rootPath) {
  try {
    const entries = await fs.readdir(rootPath, { withFileTypes: true });
    const dirs = entries
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name)
      .sort()
      .reverse();
    if (dirs.length === 0) {
      return null;
    }
    return path.join(rootPath, dirs[0]);
  } catch {
    return null;
  }
}

async function findLatestFile(rootPath, matcher, maxEntries) {
  const stack = [rootPath];
  let visited = 0;
  let latestPath = null;
  let latestMtime = -1;

  while (stack.length > 0) {
    const current = stack.pop();
    let entries;
    try {
      entries = await fs.readdir(current, { withFileTypes: true });
    } catch {
      continue;
    }

    for (const entry of entries) {
      visited += 1;
      if (visited > maxEntries) {
        break;
      }
      const fullPath = path.join(current, entry.name);
      if (entry.isDirectory()) {
        stack.push(fullPath);
        continue;
      }
      if (!entry.isFile()) {
        continue;
      }
      if (!matcher(entry.name, fullPath)) {
        continue;
      }
      let stats;
      try {
        stats = await fs.stat(fullPath);
      } catch {
        continue;
      }
      if (stats.mtimeMs > latestMtime) {
        latestMtime = stats.mtimeMs;
        latestPath = fullPath;
      }
    }
    if (visited > maxEntries) {
      break;
    }
  }

  return latestPath;
}

async function readFileTail(filePath, maxBytes) {
  const stats = await fs.stat(filePath);
  const start = Math.max(0, stats.size - maxBytes);
  const length = Math.max(0, stats.size - start);
  if (length === 0) {
    return "";
  }
  const handle = await fs.open(filePath, "r");
  try {
    const buffer = Buffer.alloc(length);
    await handle.read(buffer, 0, length, start);
    // Tail reads keep parsing fast even when logs are large.
    return buffer.toString("utf8");
  } finally {
    await handle.close();
  }
}

function parseLastAutocompactUsage(text) {
  const regex = /autocompact:\s*tokens=(\d+)\s+threshold=(\d+)/g;
  let match = null;
  let current = regex.exec(text);
  while (current) {
    match = current;
    current = regex.exec(text);
  }
  if (!match) {
    return null;
  }
  return {
    tokens: Number(match[1]),
    threshold: Number(match[2]),
  };
}

function parseLastRateLimitEntry(text) {
  const lines = text.split(/\r?\n/);
  // Rate-limit evidence is historical, so the latest matching line is enough.
  for (let i = lines.length - 1; i >= 0; i -= 1) {
    const line = lines[i];
    if (!/rate[_ -]?limit|429/i.test(line)) {
      continue;
    }
    return {
      timestamp: extractTimestamp(line),
      line: line.trim(),
    };
  }
  return null;
}

function extractTimestamp(line) {
  const match = line.match(/^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})/);
  if (!match) {
    return null;
  }
  return match[1];
}

function expandHome(inputPath) {
  if (!inputPath) {
    return inputPath;
  }
  if (inputPath === "~") {
    return os.homedir();
  }
  if (inputPath.startsWith("~/")) {
    return path.join(os.homedir(), inputPath.slice(2));
  }
  return inputPath;
}

async function readJsonIfExists(filePath) {
  try {
    const raw = await fs.readFile(filePath, "utf8");
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function tryParseJson(text) {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

function numberOrNull(value) {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function formatSnapshot(snapshot) {
  const lines = [];
  lines.push(
    `LimitLens Snapshot: ${formatTimestampDual(snapshot.capturedAt)} (${ageFromIso(snapshot.capturedAt)})`,
  );
  lines.push("");
  lines.push(formatCodex(snapshot.providers.codex));
  lines.push(formatClaude(snapshot.providers.claude));
  lines.push(formatAntigravity(snapshot.providers.antigravity));
  lines.push("");
  // Keep uncertainty explicit so we never overstate quota precision.
  lines.push("Note: exact remaining quota is only shown when provider logs expose it.");
  return `${lines.join("\n")}\n`;
}

function formatCodex(codex) {
  if (!codex || !codex.available) {
    return `Codex: unavailable (${codex && codex.reason ? codex.reason : "no data"})`;
  }
  const primary = codex.rateLimits && codex.rateLimits.primary ? codex.rateLimits.primary : null;
  const usedState =
    primary && typeof primary.used_percent === "number" ? `${primary.used_percent.toFixed(2)}% used` : "usage n/a";
  const resetIso = primary && typeof primary.resets_at === "number" ? new Date(primary.resets_at * 1000).toISOString() : null;
  const resetState = resetIso
    ? `reset=${formatTimestampDual(resetIso)} (${ageFromIso(resetIso, { futureLabel: "in" })})`
    : "reset=n/a";
  return `Codex:\n  current status: ${usedState}\n  window reset: ${resetState}\n  historical signal: none`;
}

function formatClaude(claude) {
  if (!claude || !claude.available) {
    return "Claude: unavailable";
  }
  const usageState =
    claude.latestUsage && typeof claude.latestUsage.input_tokens === "number"
      ? `last in/out=${claude.latestUsage.input_tokens}/${claude.latestUsage.output_tokens || 0}`
      : "last in/out=n/a";
  const contextState =
    claude.contextUsage && claude.contextUsage.threshold > 0
      ? `context=${claude.contextUsage.tokens}/${claude.contextUsage.threshold}`
      : "context=n/a";
  const rlState = claude.lastRateLimit
    ? `${formatLineTimestamp(claude.lastRateLimit.timestamp)} (${ageFromLogTimestamp(claude.lastRateLimit.timestamp)})`
    : "none";
  const extraUsage =
    claude.account && typeof claude.account.hasExtraUsageEnabled === "boolean"
      ? `extra-usage=${claude.account.hasExtraUsageEnabled ? "on" : "off"}`
      : "extra-usage=n/a";
  return [
    "Claude:",
    `  current status: ${usageState}, ${contextState}, ${extraUsage}`,
    `  historical signal: last rate-limit=${rlState}`,
  ].join("\n");
}

function formatAntigravity(antigravity) {
  if (!antigravity || !antigravity.available) {
    return "Antigravity: unavailable";
  }
  const version = antigravity.version || "version=n/a";
  const rlState = antigravity.lastRateLimit
    ? `${formatLineTimestamp(antigravity.lastRateLimit.timestamp)} (${ageFromLogTimestamp(antigravity.lastRateLimit.timestamp)})`
    : "none";
  return [
    "Antigravity:",
    `  current status: version=${version}`,
    `  historical signal: last rate-limit=${rlState}`,
  ].join("\n");
}

function formatNow() {
  return new Date().toISOString();
}

function printHelp() {
  process.stdout.write(
    [
      "LimitLens CLI",
      "",
      "Usage:",
      "  node cli.js [--json] [--watch] [--interval 60]",
      "              [--codex-path PATH] [--claude-path PATH]",
      "              [--antigravity-logs-path PATH]",
      "",
      "Examples:",
      "  node cli.js",
      "  node cli.js --json",
      "  node cli.js --watch --interval 30",
      "",
      "Defaults:",
      `  --codex-path ${DEFAULTS.codexSessionsPath}`,
      `  --claude-path ${DEFAULTS.claudeProjectsPath}`,
      `  --antigravity-logs-path ${DEFAULTS.antigravityLogsPath}`,
      "",
    ].join("\n"),
  );
}

main().catch((err) => {
  process.stderr.write(`error: ${String(err && err.message ? err.message : err)}\n`);
  process.exit(1);
});

function formatTimestampDual(isoValue) {
  const date = new Date(isoValue);
  if (Number.isNaN(date.getTime())) {
    return isoValue;
  }
  return `${date.toLocaleString()} [${date.toISOString()} UTC]`;
}

function formatLineTimestamp(logTs) {
  if (!logTs) {
    return "unknown";
  }
  const normalized = logTs.replace(" ", "T");
  return formatTimestampDual(normalized);
}

function ageFromIso(isoValue, opts = {}) {
  const futureLabel = opts.futureLabel || "in";
  const date = new Date(isoValue);
  if (Number.isNaN(date.getTime())) {
    return "age n/a";
  }
  const now = Date.now();
  const deltaMs = date.getTime() - now;
  const absMs = Math.abs(deltaMs);
  const mins = Math.round(absMs / 60000);
  if (mins < 1) {
    return deltaMs >= 0 ? `${futureLabel} <1m` : "<1m ago";
  }
  if (mins < 60) {
    return deltaMs >= 0 ? `${futureLabel} ${mins}m` : `${mins}m ago`;
  }
  const hrs = Math.round(mins / 60);
  if (hrs < 24) {
    return deltaMs >= 0 ? `${futureLabel} ${hrs}h` : `${hrs}h ago`;
  }
  const days = Math.round(hrs / 24);
  return deltaMs >= 0 ? `${futureLabel} ${days}d` : `${days}d ago`;
}

function ageFromLogTimestamp(logTs) {
  if (!logTs) {
    return "age n/a";
  }
  return ageFromIso(logTs.replace(" ", "T"));
}
