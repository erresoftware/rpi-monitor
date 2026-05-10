'use strict';

const REFRESH_INTERVAL_MS = 30_000;
const TOKEN_STORAGE_KEY = 'rpi-monitor-token';

function getToken() {
  let token = sessionStorage.getItem(TOKEN_STORAGE_KEY);
  if (!token) {
    token = window.prompt('Enter monitor auth token');
    if (token) sessionStorage.setItem(TOKEN_STORAGE_KEY, token);
  }
  return token;
}

function authHeaders() {
  const token = getToken();
  return token ? { Authorization: `Bearer ${token}` } : {};
}

function clearToken() {
  sessionStorage.removeItem(TOKEN_STORAGE_KEY);
}

function formatBytes(bytes) {
  if (bytes == null || !Number.isFinite(bytes)) return '—';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let value = bytes;
  let i = 0;
  while (value >= 1024 && i < units.length - 1) {
    value /= 1024;
    i += 1;
  }
  return `${value.toFixed(value >= 100 ? 0 : 1)} ${units[i]}`;
}

function tempColor(c) {
  if (c == null) return 'var(--color-muted)';
  if (c < 60) return 'var(--color-success)';
  if (c < 75) return 'var(--color-warning)';
  return 'var(--color-danger)';
}

function pctColor(pct) {
  if (pct == null) return 'var(--color-muted)';
  if (pct < 70) return 'var(--color-primary)';
  if (pct < 85) return 'var(--color-warning)';
  return 'var(--color-danger)';
}

function setText(id, value) {
  const el = document.getElementById(id);
  if (el) el.textContent = value ?? '—';
}

function setStyle(id, prop, value) {
  const el = document.getElementById(id);
  if (el) el.style[prop] = value;
}

function renderSnapshot(data) {
  setText('model', data.model);
  setText('os', data.os);
  setText('kernel', data.kernel);
  setText('uptime', data.uptime);

  const tempC = data.cpu?.tempC;
  setText('temp', tempC != null ? `${tempC.toFixed(1)}°C` : '—');
  setStyle('temp', 'color', tempColor(tempC));

  const throttling = document.getElementById('throttling');
  if (throttling) {
    if (data.cpu?.throttling == null) {
      throttling.textContent = '—';
      throttling.className = 'badge';
    } else if (data.cpu.throttling) {
      throttling.textContent = '⚠ Throttling active';
      throttling.className = 'badge warn';
    } else {
      throttling.textContent = '✓ No throttling';
      throttling.className = 'badge ok';
    }
  }

  setText('freq', data.cpu?.freq ?? '—');
  const la = data.loadAvg ?? {};
  setText('load', [la['1min'], la['5min'], la['15min']].filter(Boolean).join(' / ') || '—');
  setText('updates', data.updates ?? '—');

  const mem = data.memory;
  if (mem) {
    setText('mem-pct', `${mem.pct}%`);
    setText('mem-used', `${mem.usedMb} MB used`);
    setText('mem-total', `${mem.totalMb} MB total`);
    setStyle('mem-bar', 'width', `${mem.pct}%`);
    setStyle('mem-bar', 'background', pctColor(mem.pct));
  }

  const disk = data.disk;
  if (disk) {
    setText('disk-pct', `${disk.pct}%`);
    setText('disk-used', `${formatBytes(disk.usedBytes)} used`);
    setText('disk-total', `${formatBytes(disk.totalBytes)} total`);
    setStyle('disk-bar', 'width', `${disk.pct}%`);
    setStyle('disk-bar', 'background', pctColor(disk.pct));
  }

  const netBody = document.getElementById('net-body');
  if (netBody) {
    netBody.replaceChildren();
    for (const [iface, stats] of Object.entries(data.network?.interfaces ?? {})) {
      const tr = document.createElement('tr');
      tr.append(
        cell(iface),
        cell(`↓ ${formatBytes(stats.rxBytes)}`),
        cell(`↑ ${formatBytes(stats.txBytes)}`),
      );
      netBody.append(tr);
    }
  }

  setText('tcp-conn', data.network?.tcpConnections != null
    ? `Active TCP connections: ${data.network.tcpConnections}`
    : '—');

  const procBody = document.getElementById('proc-body');
  if (procBody) {
    procBody.replaceChildren();
    for (const proc of data.processes ?? []) {
      const tr = document.createElement('tr');
      const userCmd = document.createElement('td');
      const userDiv = document.createElement('div');
      userDiv.textContent = proc.user;
      userDiv.style.fontWeight = '600';
      const cmdDiv = document.createElement('div');
      cmdDiv.textContent = proc.command;
      cmdDiv.style.color = 'var(--color-muted)';
      cmdDiv.style.fontSize = '0.85em';
      userCmd.append(userDiv, cmdDiv);
      tr.append(userCmd, cell(`${proc.cpuPct}%`), cell(`${proc.memPct}%`));
      procBody.append(tr);
    }
  }
}

function cell(text) {
  const td = document.createElement('td');
  td.textContent = text;
  return td;
}

async function loadSnapshot() {
  try {
    const res = await fetch('/api', { headers: authHeaders() });
    if (res.status === 401) {
      clearToken();
      window.location.reload();
      return;
    }
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();
    renderSnapshot(data);
  } catch (error) {
    console.error('Failed to load snapshot', error);
  }
}

async function postPower(command) {
  const res = await fetch(`/${command}`, {
    method: 'POST',
    headers: { ...authHeaders(), 'Content-Type': 'application/json' },
    body: '{}',
  });
  if (!res.ok) {
    const data = await res.json().catch(() => ({}));
    throw new Error(data.error || `HTTP ${res.status}`);
  }
}

function setupPowerActions() {
  const dialog = document.getElementById('confirm-dialog');
  const titleEl = document.getElementById('dialog-title');
  const messageEl = document.getElementById('dialog-message');
  const confirmBtn = document.getElementById('dialog-confirm');

  function ask(command, label) {
    titleEl.textContent = `${label}?`;
    messageEl.textContent = `This will ${label.toLowerCase()} the device immediately.`;
    confirmBtn.value = 'confirm';
    dialog.returnValue = '';
    dialog.showModal();
    dialog.addEventListener('close', async () => {
      if (dialog.returnValue !== 'confirm') return;
      try {
        await postPower(command);
        alert(`${label} command sent`);
      } catch (error) {
        alert(`Error: ${error.message}`);
      }
    }, { once: true });
  }

  document.getElementById('btn-reboot')?.addEventListener('click', () => ask('reboot', 'Reboot'));
  document.getElementById('btn-shutdown')?.addEventListener('click', () => ask('shutdown', 'Shutdown'));
}

async function bootstrap() {
  await loadSnapshot();
  setInterval(loadSnapshot, REFRESH_INTERVAL_MS);

  try {
    const probe = await fetch('/reboot', { method: 'OPTIONS' });
    if (probe.status !== 404) {
      document.getElementById('power-actions')?.removeAttribute('hidden');
      setupPowerActions();
    }
  } catch {
    /* power endpoints not enabled */
  }
}

bootstrap();
