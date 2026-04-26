# 🖥️ Raspberry Pi Monitor

A lightweight, beautiful web-based system monitor for Raspberry Pi. Install with a single command and access your system stats from any browser on your local network.

## Features

- 🌡️ **CPU Temperature** with color indicators (green/yellow/red)
- ⚡ **CPU Frequency** in real time
- 📊 **Load Average** (1/5/15 minutes)
- 💾 **RAM Memory** usage with progress bar
- 💿 **Disk** usage with progress bar
- 🌐 **Network** traffic (received/sent per interface)
- 🔗 **Active TCP connections**
- 🔄 **Available system updates**
- ⚠️ **CPU throttling** status
- 📋 **Top 15 processes** by CPU usage
- 🔁 **Auto-refresh** every 60 seconds

## Requirements

- Raspberry Pi (any model with Raspberry Pi OS)
- Internet connection (for installation only)

## Installation

Open a terminal on your Raspberry Pi and run:

```bash
curl -fsSL https://raw.githubusercontent.com/erresoftware/rpi-monitor/main/install.sh | bash
```

The script will automatically:
1. Install Node.js (if not already installed)
2. Install PM2 process manager (if not already installed)
3. Create the monitor server
4. Start the service and configure autostart on boot
5. Display the URL to access the monitor

## Usage

After installation, open your browser and navigate to:

```
http://<your-raspberry-ip>:3002
```

The installer will show you the exact URL at the end of the installation.

## Autostart

The monitor starts automatically on boot. No manual intervention required.

## Uninstall

```bash
pm2 delete rpi-monitor
pm2 save
rm -rf ~/rpi-monitor
```

## License

MIT
