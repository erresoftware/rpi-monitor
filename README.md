# Raspberry Pi Monitor

A lightweight real-time monitoring dashboard for Raspberry Pi, built with Node.js and Express.

It displays system information such as CPU temperature, load, memory, disk usage, network stats, and running processes in a clean web interface.

---

## 🚀 Features

* CPU temperature and throttling status
* CPU frequency and load average
* RAM and disk usage with visual bars
* Network usage per interface
* Top processes by CPU usage
* System uptime and OS information
* Available package update count and package list
* Package index refresh
* Single-package upgrade or full system package upgrade
* Auto-refresh dashboard (web UI)

---

## 📦 Requirements

* Raspberry Pi (any model)
* Raspberry Pi OS (Debian-based)
* Internet connection

---

## ⚙️ Installation

Run the official installer:

```bash
curl -fsSL https://raw.githubusercontent.com/erresoftware/rpi-monitor/main/install.sh | bash
```

The script will automatically:

* Update system packages
* Install Node.js (if missing)
* Install PM2
* Configure restricted passwordless package update permissions
* Create the server
* Configure autostart
* Start the service

---

## 🌐 Access

After installation, open in your browser:

```
http://<RASPBERRY_IP>:3002
```

To find your IP:

```bash
hostname -I
```

---

## 🔐 Security

Package refresh and upgrade actions do not ask for a password in the web UI.
The installer creates a restricted `sudo` rule that only allows the monitor user
to run the package-update helper at `/usr/local/sbin/rpi-monitor-apt`.
The dashboard does not expose reboot or shutdown actions.

Keep your Raspberry Pi in a secure network. Do not expose this dashboard directly
to the internet; use a VPN or a reverse proxy with TLS and authentication if you
need remote access.

---

## 🧠 How it works

The server collects system data using Linux commands:

* `/proc`
* `vcgencmd`
* `df`, `free`, `uptime`, `ps`
* `apt list --upgradable`

and exposes them via a Node.js Express server.

The web interface is generated dynamically without frontend frameworks.

---

## 🛑 Stop service

```bash
pm2 stop rpi-monitor
```

## 🔄 Restart service

```bash
pm2 restart rpi-monitor
```

## ❌ Remove service

```bash
pm2 delete rpi-monitor
```

---

## 📁 Project structure

```
rpi-monitor/
│
├── index.js        # main server
├── package.json    # dependencies
├── install.sh      # installer script
```

---

## 👨‍💻 Author

Built for Raspberry Pi system monitoring.
