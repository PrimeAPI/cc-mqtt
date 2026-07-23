# cc:mqtt (cbus)

**cc:mqtt** (protocol name `cbus`) is a lightweight, MQTT-inspired publish/subscribe messaging broker, telemetry provider, and dashboard system built for **CC:Tweaked** (ComputerCraft) in Minecraft.

It allows you to monitor and control complex Minecraft modded infrastructure—such as Mekanism reactors, energy matrices, dynamic tanks, Create train stations, and more—across a Rednet wireless or wired network using central brokers, multi-device providers, and customizable monitor dashboards.

---

## ⚡ Parallel to MQTT

If you are familiar with the **MQTT** protocol (ISO/IEC 20922), `cc:mqtt` implements core MQTT architectural concepts over ComputerCraft's `rednet`:

| MQTT Concept | `cc:mqtt` (`cbus`) Implementation | Description |
| :--- | :--- | :--- |
| **MQTT Broker** | `broker.lua` | Central host running rednet protocol `"cbus"`. Manages entity registrations, message routing, topic matching, retained message storage, and subscriber lists. |
| **Publisher** | `provider.lua` | Connects to peripherals, collects telemetry, and periodically publishes data to topic endpoints (`publish` messages). |
| **Subscriber** | `subscriber.lua` | Listens to topic streams and renders live graphical dashboards on attached ComputerCraft monitors. |
| **Topics** | `kind/entity_name`<br>*(e.g., `energy/matrix1`, `reactor/fission1`)* | Hierarchical string identifiers used to categorize telemetry data streams. |
| **Topic Wildcards** | `+` (single-level)<br>`#` (multi-level) | Subscribers can filter topics using standard MQTT wildcards (`+` matches a single topic level, `#` matches all sub-topics). |
| **Retained Messages** | `retained[topic]` | The broker stores the latest payload for each topic and immediately delivers it to newly connected subscribers. |
| **Keep-Alive & LWT** | Heartbeat & Timeout (15s) | Providers send periodic heartbeats/data. If no message is received within 15 seconds, the broker marks the entity as offline. |
| **Command Routing** | `command` messages | Allows bi-directional messaging where subscribers or controllers send execution commands (e.g. `scram`, `activate`, `setBurnRate`) back to providers via the broker. |

---

## 🔄 Automatic OTA Updates & Commit Hash Versioning

`cc:mqtt` includes a built-in background **Auto-Updater** that continuously keeps all your in-game computers updated without manual intervention:

* **Automatic GitHub Sync**: Every 60 seconds (and on boot), each running script (`broker`, `provider`, `subscriber`) queries the GitHub Commit API (`https://api.github.com/repos/PrimeAPI/cc-mqtt/commits/main`).
* **Zero-Touch Upgrades**: When a new commit is detected on `main`, the script automatically downloads the latest code from GitHub, replaces `startup.lua`, updates `.version`, and reboots the ComputerCraft computer.
* **Commit Hash Version Metric**:
  * Every entity reports its running Git commit hash (`v:a1b2c3d`) to the network.
  * The **Broker Terminal Browser**, **Broker Inspector**, and **Monitor Overview** display the short 7-character commit hash (`VER`) for every connected provider and subscriber.

---

## 🛠️ System Architecture

### 1. `broker.lua` — Central Message Broker & Interactive Entity Browser
* **Role**: Runs rednet hosting on protocol `"cbus"` under hostname `"broker"`.
* **Features**:
  * **Interactive Terminal Entity Browser**: Browse connected providers and subscribers in real-time right on the broker computer terminal.
    * **Telemetry Inspector**: View live retained sensor readings, status, and topics for any entity.
    * **Manual Action Triggering**: Select any remote action (e.g., `scram`, `activate`, `setBurnRate`) and trigger it interactively with argument prompts.
    * **Offline Entity Cleanup**: Remove individual offline entities using `[D]` or purge all offline entities at once with `[P]`.
  * **Topic Routing**: Routes telemetry data to subscribers based on topic patterns (`+`, `#`).
  * **Retained Messages**: Retains the latest state of each published topic for instant catch-up when new subscribers join.
  * **Online Status Tracking**: Monitors active heartbeats/telemetry and flags entities as `ONLINE` or `OFFLINE`.
  * **Monitor Display**: Optional live status overview on an attached monitor showing connected entities and health.

### 2. `provider.lua` — Multi-Device Telemetry & Control Provider
* **Role**: Interrogates attached peripherals, publishes telemetry data, and handles remote commands.
* **Features**:
  * **Auto-Discovery & Naming**: Scans all attached peripherals (wired or wireless). Prompts for friendly names on first detection and saves mappings to `devices.cfg`.
  * **Supported Handlers out-of-the-box**:
    * **Mekanism**: Induction Matrix, Dynamic Tank, Fission Reactor, Industrial Turbine, Thermoelectric Boiler, Fusion Reactor, Supercritical Phase Shifter (SPS), Energy Cubes.
    * **Create**: Train Station (status, train count, state).
    * **Advanced Peripherals**: Energy Detector (inline power meter).
    * **Generic Fallback**: Introspects any unhandled peripheral with `get*` and `is*` methods automatically.
  * **Safety Watchdog**: Includes built-in safety features like **Auto-Scram** for Fission Reactors (triggers scram if temperature, damage, or waste exceed safety thresholds).
  * **Remote Actions**: Receives and executes commands sent from the network (e.g. `activate`, `scram`, `setBurnRate`, `setDumpingMode`, `setInjectionRate`).

### 3. `subscriber.lua` — Real-Time Monitor Dashboard
* **Role**: Displays live telemetry panels on connected ComputerCraft monitors.
* **Features**:
  * **Interactive Setup Mode (`startup setup`)**:
    1. **Entity Selector**: Enable/disable discovered entities and configure custom display aliases.
    2. **Visual Layout Editor**: Reposition and resize panels directly on the monitor using WASD/arrow keys, add group headers, and insert separator lines.
  * **Live Display**: Formats energy (FE, J), flow rates (mB/t), fluid contents, percentages, and status alerts with color coding and auto-stale warnings.

---

## 📥 Installation

You can install `cc:mqtt` directly onto your ComputerCraft computers using the built-in `wget` utility.

### 1. Central Broker Setup
On a ComputerCraft computer equipped with a Wireless or Wired Modem:

```bash
wget https://raw.githubusercontent.com/PrimeAPI/cc-mqtt/refs/heads/main/broker.lua startup.lua
reboot
```

*(Optional: Attach a monitor to the broker computer for a live status screen of connected entities.)*

---

### 2. Device Provider Setup
On a ComputerCraft computer connected to your modded machines (via wired modems or direct attachment):

```bash
wget https://raw.githubusercontent.com/PrimeAPI/cc-mqtt/refs/heads/main/provider.lua startup.lua
reboot
```

*On first run, the provider will prompt you in the terminal to assign friendly names to any newly detected peripherals. Configuration is automatically saved to `devices.cfg`.*

---

### 3. Dashboard Subscriber Setup
On a ComputerCraft computer connected to a Monitor:

```bash
wget https://raw.githubusercontent.com/PrimeAPI/cc-mqtt/refs/heads/main/subscriber.lua startup.lua
```

To configure the dashboard layout for the first time, run:
```bash
startup setup
```
Follow the on-screen prompts to select entities, set aliases, and position your dashboard elements on the monitor. After saving, simply run:
```bash
reboot
```
to launch the live dashboard view.

---

## 💡 Protocol Quick Reference

### Topic Structure
* `energy/<entity_name>` — Energy storage devices (Induction Matrix, Energy Cubes)
* `tank/<entity_name>` — Fluid and chemical tanks (Dynamic Tank)
* `reactor/<entity_name>` — Fission & Fusion reactors
* `sps/<entity_name>` — Supercritical Phase Shifter
* `train/<entity_name>` — Create Train Stations
* `device/<entity_name>` — Generic peripherals

### Topic Wildcards
* `+` — Single-level wildcard (e.g. `energy/+` subscribes to all energy devices)
* `#` — Multi-level wildcard (e.g. `#` subscribes to all topics across the entire network)
