#!/bin/bash
set -Eeuo pipefail

echo "======================================"
echo "  Raspberry Pi Monitor - Installation"
echo "======================================"
echo ""

# Check if running on Raspberry Pi
if ! cat /proc/device-tree/model 2>/dev/null | tr -d '\0' | grep -q "Raspberry"; then
  echo "ERROR: This script only works on Raspberry Pi!"
  exit 1
fi

# Update system
echo "[1/6] Updating system..."
export DEBIAN_FRONTEND=noninteractive
sudo apt update -qq

# Install Node.js if not present
echo "[2/6] Checking Node.js..."
if ! command -v node &> /dev/null; then
  echo "Installing Node.js..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - -qq
  sudo apt install -y nodejs -qq
fi

# Install PM2 if not present
echo "[3/6] Checking PM2..."
if ! command -v pm2 &> /dev/null; then
  echo "Installing PM2..."
  sudo npm install -g pm2 -q
fi

# Configure restricted passwordless package updater
echo "[4/6] Configuring package update permissions..."
MONITOR_USER="$(id -un)"
if ! printf '%s' "$MONITOR_USER" | grep -Eq '^[A-Za-z0-9_.-]+$'; then
  echo "ERROR: Unsupported username for sudoers: $MONITOR_USER"
  exit 1
fi

sudo tee /usr/local/sbin/rpi-monitor-apt > /dev/null <<'SH'
#!/bin/sh
set -eu

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

APT=/usr/bin/apt
APT_GET=/usr/bin/apt-get
PACKAGE_RE='^[A-Za-z0-9][A-Za-z0-9+.-]*(:[A-Za-z0-9]+)?$'

is_upgradable() {
  "$APT" list --upgradable 2>/dev/null | awk -F/ 'NR > 1 { print $1 }' | grep -Fx -- "$1" >/dev/null 2>&1
}

case "${1:-}" in
  list)
    exec "$APT" list --upgradable
    ;;
  refresh)
    exec "$APT_GET" update
    ;;
  upgrade-all)
    exec "$APT_GET" upgrade -y \
      -o Dpkg::Options::=--force-confdef \
      -o Dpkg::Options::=--force-confold
    ;;
  upgrade-one)
    package="${2:-}"
    if [ "$#" -ne 2 ] || ! printf '%s' "$package" | grep -Eq "$PACKAGE_RE"; then
      echo "Invalid package name" >&2
      exit 2
    fi
    if ! is_upgradable "$package"; then
      echo "Package is not currently listed as upgradable" >&2
      exit 3
    fi
    exec "$APT_GET" install -y --only-upgrade \
      -o Dpkg::Options::=--force-confdef \
      -o Dpkg::Options::=--force-confold \
      "$package"
    ;;
  *)
    echo "Usage: rpi-monitor-apt list|refresh|upgrade-all|upgrade-one <package>" >&2
    exit 2
    ;;
esac
SH
sudo chmod 0755 /usr/local/sbin/rpi-monitor-apt
printf '%s ALL=(root) NOPASSWD: /usr/local/sbin/rpi-monitor-apt *\n' "$MONITOR_USER" | sudo tee /etc/sudoers.d/rpi-monitor > /dev/null
sudo chmod 0440 /etc/sudoers.d/rpi-monitor
sudo visudo -cf /etc/sudoers.d/rpi-monitor > /dev/null

# Create folder and server file
echo "[5/6] Creating monitor server..."
MONITOR_DIR="$HOME/rpi-monitor"
mkdir -p "$MONITOR_DIR"
cd "$MONITOR_DIR"
npm init -y -q > /dev/null 2>&1
npm install express -q > /dev/null 2>&1

cat > "$MONITOR_DIR/index.js" << 'JSEOF'
const express = require("express");
const fs = require("fs");
const { execFileSync, spawnSync } = require("child_process");

const app = express();
const PORT = Number(process.env.PORT || 3002);
const APT_PACKAGE_RE = /^[A-Za-z0-9][A-Za-z0-9+.-]*(?::[A-Za-z0-9]+)?$/;
const APT = "/usr/bin/apt";
const SUDO = "/usr/bin/sudo";
const APT_HELPER = "/usr/local/sbin/rpi-monitor-apt";

app.disable("x-powered-by");
app.use((req, res, next) => {
  res.setHeader("X-Content-Type-Options", "nosniff");
  res.setHeader("Referrer-Policy", "same-origin");
  res.setHeader("Cache-Control", "no-store");
  res.setHeader(
    "Content-Security-Policy",
    "default-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'"
  );
  next();
});
app.use(express.json({ limit: "16kb" }));
app.use((error, req, res, next) => {
  if (error && error.type === "entity.parse.failed") {
    return res.status(400).json({ ok: false, error: "Invalid JSON body" });
  }
  next(error);
});

function run(cmd, args = [], options = {}) {
  try {
    return execFileSync(cmd, args, {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      timeout: options.timeout || 5000,
      maxBuffer: options.maxBuffer || 1024 * 256,
      env: {
        ...process.env,
        LC_ALL: "C"
      }
    }).trim();
  } catch (e) {
    return options.fallback || "N/A";
  }
}

function readText(path, fallback = "N/A") {
  try {
    return fs.readFileSync(path, "utf8").replace(/\0/g, "").trim();
  } catch (e) {
    return fallback;
  }
}

function toInt(value, fallback = 0) {
  const parsed = parseInt(value, 10);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function toNumber(value, fallback = null) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function pct(used, total) {
  return total > 0 ? `${Math.round((used / total) * 100)}%` : "N/A";
}

function escapeHtml(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function escapeAttr(value) {
  return escapeHtml(value).replace(/`/g, "&#96;");
}

function parseOsRelease() {
  const osRelease = readText("/etc/os-release", "");
  const pretty = osRelease.split("\n").find(line => line.startsWith("PRETTY_NAME="));
  return pretty ? pretty.replace("PRETTY_NAME=", "").replace(/^"|"$/g, "") : "N/A";
}

function getAvailableUpdates() {
  const output = run(APT, ["list", "--upgradable"], {
    timeout: 15000,
    maxBuffer: 1024 * 1024,
    fallback: ""
  });

  return output
    .split("\n")
    .map(line => line.trim())
    .filter(line => line && !line.startsWith("Listing"))
    .map(line => {
      const match = line.match(/^([^/\s]+)\/\S+\s+(\S+)\s+(\S+)(?:\s+\[upgradable from:\s*(.*?)\])?$/);
      if (!match) {
        const name = line.split("/")[0] || line;
        return { name, current: "N/A", candidate: "N/A", arch: "N/A", raw: line };
      }
      return {
        name: match[1],
        candidate: match[2],
        arch: match[3],
        current: match[4] || "N/A",
        raw: line
      };
    })
    .filter(pkg => APT_PACKAGE_RE.test(pkg.name))
    .sort((a, b) => a.name.localeCompare(b.name));
}

function getNet() {
  const lines = readText("/proc/net/dev", "").split("\n");
  const ifaces = {};
  lines.forEach(line => {
    const match = line.trim().match(/^(eth0|br0|wlan0):\s+(.+)$/);
    if (!match) return;
    const fields = match[2].trim().split(/\s+/);
    const rx = toInt(fields[0]);
    const tx = toInt(fields[8]);
    ifaces[match[1]] = {
      rx: `${Math.round(rx / 1024 / 1024)} MB`,
      tx: `${Math.round(tx / 1024 / 1024)} MB`
    };
  });
  return ifaces;
}

function getProcesses() {
  const output = run("ps", ["-eo", "user=,comm=,pcpu=,pmem=", "--sort=-pcpu"], {
    maxBuffer: 1024 * 512,
    fallback: ""
  });
  return output
    .split("\n")
    .map(line => line.trim())
    .filter(Boolean)
    .slice(0, 15)
    .map(line => {
      const parts = line.split(/\s+/);
      return {
        user: parts[0] || "N/A",
        command: parts[1] || "N/A",
        cpu: parts[2] || "0.0",
        mem: parts[3] || "0.0"
      };
    });
}

function getData() {
  const tempRaw = run("vcgencmd", ["measure_temp"]).replace("temp=", "").replace("'C", "");
  const temp = toNumber(tempRaw);
  const memLine = run("free", ["-m"]).split("\n").find(line => line.trim().startsWith("Mem:")) || "";
  const mem = memLine.trim().split(/\s+/);
  const diskLine = run("df", ["-h", "/"]).split("\n")[1] || "";
  const disk = diskLine.trim().split(/\s+/);
  const uptime = run("uptime", ["-p"]);
  const load = readText("/proc/loadavg", "N/A N/A N/A").split(/\s+/);
  const freq = readText("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq");
  const freqMhz = freq !== "N/A" ? `${Math.round(toInt(freq) / 1000)} MHz` : "N/A";
  const route = run("ip", ["route", "get", "1"]);
  const ipMatch = route.match(/\bsrc\s+(\S+)/);
  const ip = ipMatch ? ipMatch[1] : "N/A";
  const throttledRaw = run("vcgencmd", ["get_throttled"]);
  const model = readText("/proc/device-tree/model");
  const kernel = run("uname", ["-r"]);
  const os = parseOsRelease();
  const updatePackages = getAvailableUpdates();
  const ss = run("ss", ["-s"]);
  const connTCP = ss.split("\n").find(line => line.trim().startsWith("TCP:")) || "N/A";
  const net = getNet();
  const memoryTotal = toInt(mem[1]);
  const memoryUsed = toInt(mem[2]);

  return {
    model, kernel, os,
    updates: updatePackages.length,
    update_count: updatePackages.length,
    updatePackages,
    temp_c: temp,
    throttled: throttledRaw === "throttled=0x0",
    throttled_status: throttledRaw,
    freq: freqMhz,
    load_avg: { "1min": load[0], "5min": load[1], "15min": load[2] },
    memory: { total_mb: memoryTotal, used_mb: memoryUsed, pct: pct(memoryUsed, memoryTotal) },
    disk: { total: disk[1] || "N/A", used: disk[2] || "N/A", free: disk[3] || "N/A", pct: disk[4] || "N/A" },
    ip, connTCP, net,
    uptime,
    processes: getProcesses()
  };
}

app.get('/api', (req, res) => res.json(getData()));
app.get('/api/updates', (req, res) => res.json({ ok: true, packages: getAvailableUpdates() }));

function cleanAptOutput(output) {
  return String(output || "")
    .split("\n")
    .slice(-80)
    .join("\n")
    .trim();
}

function runAptHelper(args, timeout = 10 * 60 * 1000) {
  const result = spawnSync(SUDO, ["-n", APT_HELPER, ...args], {
    encoding: "utf8",
    timeout,
    maxBuffer: 1024 * 1024,
    env: {
      ...process.env,
      DEBIAN_FRONTEND: "noninteractive",
      LC_ALL: "C"
    }
  });

  if (result.error) {
    const error = new Error(result.error.code === "ETIMEDOUT" ? "Operation timed out" : result.error.message);
    error.status = 500;
    throw error;
  }

  if (result.status !== 0) {
    const message = cleanAptOutput(result.stderr) || cleanAptOutput(result.stdout) || "apt-get failed";
    const error = new Error(message);
    error.status = /password|authentication|sudo/i.test(message) ? 403 : 500;
    throw error;
  }

  return {
    stdout: cleanAptOutput(result.stdout),
    stderr: cleanAptOutput(result.stderr)
  };
}

function sendAptError(res, error) {
  const status = error.status || 500;
  res.status(status).json({
    ok: false,
    error: String(error.message || "Unexpected error").slice(0, 1200)
  });
}

app.post('/api/updates/refresh', (req, res) => {
  try {
    const result = runAptHelper(["refresh"]);
    const packages = getAvailableUpdates();
    res.json({ ok: true, updates: packages.length, packages, output: result.stdout || result.stderr });
  } catch (error) {
    sendAptError(res, error);
  }
});

app.post('/api/updates/install', (req, res) => {
  try {
    const packageName = req.body && req.body.package;
    const updateAll = Boolean(req.body && req.body.all);

    if (updateAll) {
      const result = runAptHelper(["upgrade-all"], 30 * 60 * 1000);
      const packages = getAvailableUpdates();
      return res.json({ ok: true, updates: packages.length, packages, output: result.stdout || result.stderr });
    }

    if (typeof packageName !== "string" || !APT_PACKAGE_RE.test(packageName)) {
      return res.status(400).json({ ok: false, error: "Invalid package name" });
    }

    const packagesBefore = getAvailableUpdates();
    if (!packagesBefore.some(pkg => pkg.name === packageName)) {
      return res.status(404).json({ ok: false, error: "Package is not currently listed as upgradable" });
    }

    const result = runAptHelper(["upgrade-one", packageName], 20 * 60 * 1000);
    const packages = getAvailableUpdates();
    res.json({ ok: true, updates: packages.length, packages, output: result.stdout || result.stderr });
  } catch (error) {
    sendAptError(res, error);
  }
});

app.get('/', (req, res) => {
  const d = getData();
  const memPct = toInt(d.memory.pct);
  const diskPct = toInt(d.disk.pct);
  const tempColor = d.temp_c === null ? '#8a8680' : d.temp_c < 60 ? '#2d6a4f' : d.temp_c < 75 ? '#b5840a' : '#c0392b';
  const memColor = memPct < 70 ? '#2c3e50' : memPct < 85 ? '#b5840a' : '#c0392b';
  const diskColor = diskPct < 70 ? '#2c3e50' : diskPct < 85 ? '#b5840a' : '#c0392b';
  const updColor = d.updates === 0 ? '#2d6a4f' : d.updates < 10 ? '#b5840a' : '#c0392b';

  const procRows = d.processes.map(p => {
    return '<tr><td><div style="font-weight:600">' + escapeHtml(p.user) + '</div><div style="color:#8a8680;word-break:break-all;font-size:0.85em">' + escapeHtml(p.command) + '</div></td><td>' + escapeHtml(p.cpu) + '</td><td>' + escapeHtml(p.mem) + '</td></tr>';
  }).join('');

  const netRows = Object.entries(d.net).map(([iface, v]) =>
    '<tr><td>' + escapeHtml(iface) + '</td><td>↓ ' + escapeHtml(v.rx) + '</td><td>↑ ' + escapeHtml(v.tx) + '</td></tr>'
  ).join('') || '<tr><td colspan="3">N/A</td></tr>';

  const updateRows = d.updatePackages.length === 0
    ? '<tr><td colspan="4" class="empty">System is up to date</td></tr>'
    : d.updatePackages.map(pkg =>
        '<tr><td><div style="font-weight:600;word-break:break-word">' + escapeHtml(pkg.name) + '</div><div style="color:#8a8680;font-size:0.85em">' + escapeHtml(pkg.arch) + '</div></td><td>' + escapeHtml(pkg.current) + '</td><td>' + escapeHtml(pkg.candidate) + '</td><td><button class="btn btn-small" data-package="' + escapeAttr(pkg.name) + '" onclick="askUpdate(\'package\', this.dataset.package)">Update</button></td></tr>'
      ).join('');

  const html = '<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><meta http-equiv="refresh" content="60"><title>Raspberry Monitor</title><style>*{box-sizing:border-box;margin:0;padding:0}body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:#f5f4f0;color:#1a1916;padding:32px}header{margin-bottom:32px;border-bottom:2px solid #2c3e50;padding-bottom:16px}h1{font-size:1.6em;font-weight:700}.subtitle{font-family:"SFMono-Regular",Consolas,monospace;font-size:0.8em;color:#8a8680;margin-top:4px;line-height:1.5}.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));gap:16px;margin-bottom:16px}.card{background:#fff;border:1px solid #e0ddd6;border-radius:8px;padding:20px}.card-wide{grid-column:1/-1}.card-head{display:flex;align-items:flex-start;justify-content:space-between;gap:16px;margin-bottom:12px}.label{font-size:0.7em;font-weight:700;letter-spacing:0.08em;text-transform:uppercase;color:#8a8680;margin-bottom:8px}.value{font-family:"SFMono-Regular",Consolas,monospace;font-size:2em;font-weight:700;line-height:1}.bar-bg{background:#e0ddd6;border-radius:4px;height:8px;margin-top:12px;overflow:hidden}.bar{height:100%;border-radius:4px}.bar-labels{display:flex;justify-content:space-between;gap:12px;font-family:"SFMono-Regular",Consolas,monospace;font-size:0.7em;color:#8a8680;margin-top:6px}.dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:8px}.table-wrap{width:100%;overflow-x:auto}table{width:100%;border-collapse:collapse;font-family:"SFMono-Regular",Consolas,monospace;font-size:0.8em;table-layout:fixed}th{text-align:left;padding:8px 12px;background:#f5f4f0;color:#8a8680;font-weight:700;font-size:0.75em;letter-spacing:0.06em;text-transform:uppercase}td{padding:8px 12px;border-bottom:1px solid #e0ddd6;vertical-align:middle;overflow-wrap:anywhere}tr:last-child td{border-bottom:none}.empty{color:#2d6a4f;font-weight:700;text-align:center}.actions{display:flex;gap:8px;align-items:center;flex-wrap:wrap}.btn{font-family:"SFMono-Regular",Consolas,monospace;font-size:0.8em;padding:8px 14px;border:1px solid #2c3e50;background:#2c3e50;color:#fff;border-radius:4px;cursor:pointer;min-height:34px}.btn:hover{filter:brightness(1.08)}.btn:disabled{opacity:.45;cursor:not-allowed}.btn-secondary{background:#fff;color:#2c3e50}.btn-small{padding:6px 10px;min-height:30px}.status{font-family:"SFMono-Regular",Consolas,monospace;font-size:0.75em;color:#8a8680;min-height:18px;margin-top:10px;white-space:pre-wrap}@media(max-width:640px){body{padding:18px}.card-head{display:block}.actions{margin-top:12px}.value{font-size:1.65em}table{min-width:560px}}</style></head><body>'
  + '<header><h1>' + escapeHtml(d.model) + '</h1><div class="subtitle">' + escapeHtml(d.os) + ' &nbsp;·&nbsp; Kernel ' + escapeHtml(d.kernel) + ' &nbsp;·&nbsp; ' + escapeHtml(d.uptime) + ' &nbsp;·&nbsp; IP ' + escapeHtml(d.ip) + '</div></header>'
  + '<div class="grid">'
  + '<div class="card"><div class="label">CPU Temperature</div><div class="value" style="color:' + tempColor + '">' + escapeHtml(d.temp_c === null ? 'N/A' : d.temp_c + '°C') + '</div><div style="font-size:0.8em;color:' + (d.throttled?'#2d6a4f':'#c0392b') + ';margin-top:8px;font-family:SFMono-Regular,Consolas,monospace">' + escapeHtml(d.throttled_status === "N/A" ? "Throttling N/A" : d.throttled ? "No throttling" : "Throttling active") + '</div></div>'
  + '<div class="card"><div class="label">CPU Frequency</div><div class="value">' + escapeHtml(d.freq) + '</div></div>'
  + '<div class="card"><div class="label">Load Average</div><div class="value" style="font-size:1.4em">' + escapeHtml(d.load_avg['1min']) + ' / ' + escapeHtml(d.load_avg['5min']) + ' / ' + escapeHtml(d.load_avg['15min']) + '</div></div>'
  + '<div class="card"><div class="label">Available Updates</div><div class="value" style="color:' + updColor + '">' + escapeHtml(d.updates) + '</div></div>'
  + '<div class="card"><div class="label">RAM Memory</div><div class="value">' + escapeHtml(d.memory.pct) + '</div><div class="bar-bg"><div class="bar" style="width:' + escapeAttr(d.memory.pct) + ';background:' + memColor + '"></div></div><div class="bar-labels"><span>' + escapeHtml(d.memory.used_mb) + ' MB used</span><span>' + escapeHtml(d.memory.total_mb) + ' MB total</span></div></div>'
  + '<div class="card"><div class="label">Disk</div><div class="value">' + escapeHtml(d.disk.pct) + '</div><div class="bar-bg"><div class="bar" style="width:' + escapeAttr(d.disk.pct) + ';background:' + diskColor + '"></div></div><div class="bar-labels"><span>' + escapeHtml(d.disk.used) + ' used</span><span>' + escapeHtml(d.disk.total) + ' total</span></div></div>'
  + '<div class="card card-wide"><div class="card-head"><div><div class="label">Package Updates</div><div class="value" style="color:' + updColor + '">' + escapeHtml(d.updates) + '</div></div><div class="actions"><button class="btn btn-secondary" onclick="askUpdate(\'refresh\')">Refresh list</button><button class="btn" onclick="askUpdate(\'all\')" data-disabled="' + (d.updates === 0 ? 'true' : 'false') + '" ' + (d.updates === 0 ? 'disabled' : '') + '>Update all</button></div></div><div class="table-wrap"><table><colgroup><col style="width:40%"><col style="width:24%"><col style="width:24%"><col style="width:12%"></colgroup><thead><tr><th>Package</th><th>Current</th><th>New</th><th>Action</th></tr></thead><tbody>' + updateRows + '</tbody></table></div><div class="status" id="update-status"></div></div>'
  + '</div>'
  + '<div class="grid">'
  + '<div class="card"><div class="label">Network (session total)</div><div class="table-wrap"><table><thead><tr><th>Interface</th><th>Received</th><th>Sent</th></tr></thead><tbody>' + netRows + '</tbody></table></div><div style="font-family:SFMono-Regular,Consolas,monospace;font-size:0.75em;color:#8a8680;margin-top:12px">' + escapeHtml(d.connTCP) + '</div></div>'
  + '</div>'
  + '<div class="card"><div class="label" style="margin-bottom:16px">Processes</div><div class="table-wrap"><table><colgroup><col style="width:60%"><col style="width:20%"><col style="width:20%"></colgroup><thead><tr><th><div>User</div><div style="font-weight:400;font-size:0.85em;color:#8a8680">Process</div></th><th>CPU</th><th>Mem</th></tr></thead><tbody>' + procRows + '</tbody></table></div></div>'
  + '<script>let working=false;function setStatus(text){const el=document.getElementById("update-status");if(el)el.textContent=text||"";}function setBusy(busy){working=busy;document.querySelectorAll("button").forEach(btn=>{if(btn.textContent.includes("Update")||btn.textContent.includes("Refresh"))btn.disabled=busy||btn.dataset.disabled==="true";});}async function askUpdate(action,packageName){if(working)return;if(action==="all"&&!confirm("Update all packages?"))return;if(action==="package"&&!confirm("Update "+packageName+"?"))return;setBusy(true);setStatus("Working...");try{const refresh=action==="refresh";const body=refresh?{}:{all:action==="all",package:packageName};const response=await fetch(refresh?"/api/updates/refresh":"/api/updates/install",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(body)});const data=await response.json().catch(()=>({error:"Invalid server response"}));if(!response.ok||!data.ok)throw new Error(data.error||"Update failed");setStatus("Done. Reloading...");window.location.reload();}catch(error){setStatus("Error: "+error.message);setBusy(false);}}</script>'
  + '</body></html>';

  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  res.send(html);
});

app.listen(PORT, () => {
  console.log('Raspberry Monitor running at http://localhost:' + PORT);
});
JSEOF

# Start with PM2
echo "[6/6] Starting and configuring autostart..."
if pm2 describe rpi-monitor > /dev/null 2>&1; then
  pm2 restart rpi-monitor --update-env > /dev/null 2>&1
else
  pm2 start "$MONITOR_DIR/index.js" --name rpi-monitor > /dev/null 2>&1
fi
pm2 save > /dev/null 2>&1
STARTUP_CMD=$(pm2 startup 2>/dev/null | grep "sudo" || true)
if [ -n "$STARTUP_CMD" ]; then
  echo "$STARTUP_CMD" | bash > /dev/null 2>&1 || true
fi

IP=$(hostname -I | awk '{print $1}')
echo ""
echo "======================================"
echo "  Installation complete!"
echo "======================================"
echo ""
echo "  Open in your browser:"
echo "  http://$IP:3002"
echo ""
