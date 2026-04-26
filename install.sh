#!/bin/bash

echo “======================================”
echo “  Raspberry Pi Monitor - Installation”
echo “======================================”
echo “”

# Check if running on Raspberry Pi

if ! cat /proc/device-tree/model 2>/dev/null | tr -d '\0' | grep -q "Raspberry"; then
echo “ERROR: This script only works on Raspberry Pi!”
exit 1
fi

# Update system

echo “[1/5] Updating system…”
sudo apt update -qq

# Install Node.js if not present

echo “[2/5] Checking Node.js…”
if ! command -v node &> /dev/null; then
echo “Installing Node.js…”
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - -qq
sudo apt install -y nodejs -qq
fi

# Install PM2 if not present

echo “[3/5] Checking PM2…”
if ! command -v pm2 &> /dev/null; then
echo “Installing PM2…”
sudo npm install -g pm2 -q
fi

# Create folder and server file

echo “[4/5] Creating monitor server…”
mkdir -p ~/rpi-monitor
cd ~/rpi-monitor
npm init -y -q > /dev/null 2>&1
npm install express -q > /dev/null 2>&1

cat > ~/rpi-monitor/index.js << ‘JSEOF’
const express = require(“express”);
const { execSync } = require(“child_process”);
const app = express();
const PORT = 3002;

app.use(express.json());

function run(cmd) {
try { return execSync(cmd).toString().trim(); } catch(e) { return “N/A”; }
}

function getNet() {
const lines = run(“cat /proc/net/dev”).split(’\n’);
const ifaces = {};
lines.forEach(l => {
const m = l.trim().match(/^(eth0|br0|wlan0):\s+(\d+)\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+(\d+)/);
if (m) ifaces[m[1]] = { rx: Math.round(parseInt(m[2])/1024/1024) + ’ MB’, tx: Math.round(parseInt(m[3])/1024/1024) + ’ MB’ };
});
return ifaces;
}

function getData() {
const temp = run(“vcgencmd measure_temp”).replace(‘temp=’,’’).replace(”‘C”,’’);
const mem = run(“free -m | grep Mem”).split(/\s+/);
const disk = run(“df -h / | tail -1”).split(/\s+/);
const uptime = run(“uptime -p”);
const load = run(“cat /proc/loadavg”).split(’ ‘);
const freq = run(“cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq”);
const freqMhz = freq !== ‘N/A’ ? Math.round(parseInt(freq)/1000) + ’ MHz’ : ‘N/A’;
const ip = run(“ip route get 1 | awk ‘{print $7;exit}’”);
const throttled = run(“vcgencmd get_throttled”) === ‘throttled=0x0’;
const model = run(“cat /proc/device-tree/model 2>/dev/null”).replace(/\0/g,’’);
const kernel = run(“uname -r”);
const os = run(“cat /etc/os-release | grep PRETTY_NAME”).replace(‘PRETTY_NAME=’,’’).replace(/”/g,’’);
const updates = Math.max(0, parseInt(run(“apt list –upgradable 2>/dev/null | wc -l”)) - 1);
const connTCP = run(“ss -s | grep TCP | head -1”);
const net = getNet();
const processes = run(“ps aux –no-headers –sort=-%cpu | grep -v ‘\[.*\]’ | head -15 | awk ‘{n=split($11,a,"/"); printf "%s %s %s %s\n", $1, a[n], $3, $4}’”);
return {
model, kernel, os, updates,
temp_c: parseFloat(temp),
throttled,
freq: freqMhz,
load_avg: { “1min”: load[0], “5min”: load[1], “15min”: load[2] },
memory: { total_mb: parseInt(mem[1]), used_mb: parseInt(mem[2]), pct: Math.round(parseInt(mem[2])/parseInt(mem[1])*100) + ‘%’ },
disk: { total: disk[1], used: disk[2], free: disk[3], pct: disk[4] },
ip, connTCP, net,
uptime,
processes: processes.split(’\n’).filter(p => p.trim())
};
}

app.get(’/api’, (req, res) => res.json(getData()));

app.post(’/reboot’, (req, res) => {
const { password } = req.body;
if (!password) return res.status(400).json({ error: ‘Password required’ });
try {
execSync(‘echo ’ + JSON.stringify(password) + ’ | sudo -S reboot 2>&1’);
res.json({ ok: true });
} catch(e) {
res.status(403).json({ error: ‘Wrong password or permission denied’ });
}
});

app.post(’/shutdown’, (req, res) => {
const { password } = req.body;
if (!password) return res.status(400).json({ error: ‘Password required’ });
try {
execSync(‘echo ’ + JSON.stringify(password) + ’ | sudo -S shutdown -h now 2>&1’);
res.json({ ok: true });
} catch(e) {
res.status(403).json({ error: ‘Wrong password or permission denied’ });
}
});

app.get(’/’, (req, res) => {
const d = getData();
const memPct = parseInt(d.memory.pct);
const diskPct = parseInt(d.disk.pct);
const tempColor = d.temp_c < 60 ? ‘#2d6a4f’ : d.temp_c < 75 ? ‘#b5840a’ : ‘#c0392b’;
const memColor = memPct < 70 ? ‘#2c3e50’ : memPct < 85 ? ‘#b5840a’ : ‘#c0392b’;
const diskColor = diskPct < 70 ? ‘#2c3e50’ : diskPct < 85 ? ‘#b5840a’ : ‘#c0392b’;
const updColor = d.updates === 0 ? ‘#2d6a4f’ : d.updates < 10 ? ‘#b5840a’ : ‘#c0392b’;

const procRows = d.processes.map(p => {
const parts = p.split(’ ‘);
return ‘<tr><td><div style="font-weight:600">’ + (parts[0]||’’) + ‘</div><div style="color:#8a8680;word-break:break-all;font-size:0.85em">’ + (parts[1]||’’) + ‘</div></td><td>’ + (parts[2]||’’) + ‘</td><td>’ + (parts[3]||’’) + ‘</td></tr>’;
}).join(’’);

const netRows = Object.entries(d.net).map(([iface, v]) =>
‘<tr><td>’ + iface + ‘</td><td>↓ ’ + v.rx + ‘</td><td>↑ ’ + v.tx + ‘</td></tr>’
).join(’’);

const html = ‘<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><meta http-equiv="refresh" content="60"><title>Raspberry Monitor</title><link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;600&family=IBM+Plex+Sans:wght@300;500;700&display=swap" rel="stylesheet"><style>*{box-sizing:border-box;margin:0;padding:0}body{font-family:“IBM Plex Sans”,sans-serif;background:#f5f4f0;color:#1a1916;padding:32px}header{margin-bottom:32px;border-bottom:2px solid #2c3e50;padding-bottom:16px}h1{font-size:1.6em;font-weight:700}.subtitle{font-family:“IBM Plex Mono”,monospace;font-size:0.8em;color:#8a8680;margin-top:4px}.actions{margin-top:16px;display:flex;gap:8px}.btn{font-family:“IBM Plex Mono”,monospace;font-size:0.8em;padding:8px 16px;border:1px solid #2c3e50;background:#2c3e50;color:#fff;border-radius:4px;cursor:pointer}.btn-danger{background:#c0392b;border-color:#c0392b}.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));gap:16px;margin-bottom:16px}.card{background:#fff;border:1px solid #e0ddd6;border-radius:8px;padding:20px}.label{font-size:0.7em;font-weight:500;letter-spacing:0.1em;text-transform:uppercase;color:#8a8680;margin-bottom:8px}.value{font-family:“IBM Plex Mono”,monospace;font-size:2em;font-weight:600;line-height:1}.bar-bg{background:#e0ddd6;border-radius:4px;height:8px;margin-top:12px;overflow:hidden}.bar{height:100%;border-radius:4px}.bar-labels{display:flex;justify-content:space-between;font-family:“IBM Plex Mono”,monospace;font-size:0.7em;color:#8a8680;margin-top:6px}table{width:100%;border-collapse:collapse;font-family:“IBM Plex Mono”,monospace;font-size:0.8em;table-layout:fixed}th{text-align:left;padding:8px 12px;background:#f5f4f0;color:#8a8680;font-weight:500;font-size:0.75em;letter-spacing:0.08em;text-transform:uppercase}td{padding:8px 12px;border-bottom:1px solid #e0ddd6}tr:last-child td{border-bottom:none}.modal{display:none;position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,0.5);z-index:1000;align-items:center;justify-content:center}.modal.show{display:flex}.modal-box{background:#fff;padding:32px;border-radius:8px;width:320px}.modal-box h2{margin-bottom:16px;font-size:1.2em}.modal-box input{width:100%;padding:8px;border:1px solid #e0ddd6;border-radius:4px;font-family:“IBM Plex Mono”,monospace;margin-bottom:16px;font-size:1em}.modal-actions{display:flex;gap:8px;justify-content:flex-end}</style></head><body>’

- ‘<header><h1>’ + d.model + ‘</h1><div class="subtitle">’ + d.os + ’  ·  Kernel ’ + d.kernel + ’  ·  ’ + d.uptime + ‘</div>’
- ‘<div class="actions"><button class="btn" onclick="askCommand(\'/reboot\')">⟳ Reboot</button><button class="btn btn-danger" onclick="askCommand(\'/shutdown\')">⏻ Shutdown</button></div></header>’
- ‘<div class="grid">’
- ‘<div class="card"><div class="label">CPU Temperature</div><div class="value" style="color:' + tempColor + '">’ + d.temp_c + ‘°C</div><div style="font-size:0.8em;color:' + (d.throttled?'#2d6a4f':'#c0392b') + ';margin-top:8px;font-family:IBM Plex Mono,monospace">’ + (d.throttled?‘✓ No throttling’:‘⚠ Throttling active’) + ‘</div></div>’
- ‘<div class="card"><div class="label">CPU Frequency</div><div class="value">’ + d.freq + ‘</div></div>’
- ‘<div class="card"><div class="label">Load Average</div><div class="value" style="font-size:1.4em">’ + d.load_avg[‘1min’] + ’ / ’ + d.load_avg[‘5min’] + ’ / ’ + d.load_avg[‘15min’] + ‘</div></div>’
- ‘<div class="card"><div class="label">Available Updates</div><div class="value" style="color:' + updColor + '">’ + d.updates + ‘</div></div>’
- ‘<div class="card"><div class="label">RAM Memory</div><div class="value">’ + d.memory.pct + ‘</div><div class="bar-bg"><div class="bar" style="width:' + d.memory.pct + ';background:' + memColor + '"></div></div><div class="bar-labels"><span>’ + d.memory.used_mb + ’ MB used</span><span>’ + d.memory.total_mb + ’ MB total</span></div></div>’
- ‘<div class="card"><div class="label">Disk</div><div class="value">’ + d.disk.pct + ‘</div><div class="bar-bg"><div class="bar" style="width:' + d.disk.pct + ';background:' + diskColor + '"></div></div><div class="bar-labels"><span>’ + d.disk.used + ’ used</span><span>’ + d.disk.total + ’ total</span></div></div>’
- ‘</div>’
- ‘<div class="grid"><div class="card"><div class="label">Network (session total)</div><table><thead><tr><th>Interface</th><th>Received</th><th>Sent</th></tr></thead><tbody>’ + netRows + ‘</tbody></table><div style="font-family:IBM Plex Mono,monospace;font-size:0.75em;color:#8a8680;margin-top:12px">’ + d.connTCP + ‘</div></div></div>’
- ‘<div class="card"><div class="label" style="margin-bottom:16px">Processes</div><table><colgroup><col style="width:60%"><col style="width:20%"><col style="width:20%"></colgroup><thead><tr><th><div>User</div><div style="font-weight:300;font-size:0.85em;color:#8a8680">Process</div></th><th>CPU</th><th>Mem</th></tr></thead><tbody>’ + procRows + ‘</tbody></table></div>’
- ‘<div class="modal" id="modal"><div class="modal-box"><h2 id="modal-title">Confirm</h2><input type="password" id="modal-pwd" placeholder="Enter your password" /><div class="modal-actions"><button class="btn" style="background:#8a8680;border-color:#8a8680" onclick="closeModal()">Cancel</button><button class="btn" id="modal-confirm">Confirm</button></div></div></div>’
- ‘<script>let _cmd=””;function askCommand(cmd){_cmd=cmd;document.getElementById(“modal-title”).textContent=cmd===”/reboot”?“Reboot Raspberry Pi?”:“Shutdown Raspberry Pi?”;document.getElementById(“modal-pwd”).value=””;const btn=document.getElementById(“modal-confirm”);btn.className=cmd===”/shutdown”?“btn btn-danger”:“btn”;btn.onclick=sendCommand;document.getElementById(“modal”).classList.add(“show”);setTimeout(()=>document.getElementById(“modal-pwd”).focus(),100);}function closeModal(){document.getElementById(“modal”).classList.remove(“show”);}async function sendCommand(){const pwd=document.getElementById(“modal-pwd”).value;if(!pwd)return;const r=await fetch(_cmd,{method:“POST”,headers:{“Content-Type”:“application/json”},body:JSON.stringify({password:pwd})});const d=await r.json();if(d.ok){closeModal();alert(_cmd===”/reboot”?“Rebooting…”:“Shutting down…”);}else{alert(“Error: “+d.error);}}</script>’
- ‘</body></html>’;

res.setHeader(‘Content-Type’, ‘text/html; charset=utf-8’);
res.send(html);
});

app.listen(PORT, () => {
console.log(‘Raspberry Monitor running at http://localhost:’ + PORT);
});
JSEOF

# Start with PM2

echo “[5/5] Starting and configuring autostart…”
pm2 delete rpi-monitor 2>/dev/null || true
pm2 start ~/rpi-monitor/index.js –name rpi-monitor > /dev/null 2>&1
pm2 save > /dev/null 2>&1
pm2 startup 2>/dev/null | grep “sudo” | bash > /dev/null 2>&1

IP=$(hostname -I | awk ‘{print $1}’)
echo “”
echo “======================================”
echo “  Installation complete!”
echo “======================================”
echo “”
echo “  Open in your browser:”
echo “  http://$IP:3002”
echo “”