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
| **Automation Server** | `controller.lua` | Listens to all network telemetry, evaluates user automations/triggers, executes remote actions, and renders status & audit logs on attached monitors. |
| **Topics** | `kind/entity_name`<br>*(e.g., `energy/matrix1`, `reactor/fission1`)* | Hierarchical string identifiers used to categorize telemetry data streams. |
| **Topic Wildcards** | `+` (single-level)<br>`#` (multi-level) | Subscribers can filter topics using standard MQTT wildcards (`+` matches a single topic level, `#` matches all sub-topics). |
| **Retained Messages** | `retained[topic]` | The broker stores the latest payload for each topic and immediately delivers it to newly connected subscribers. |
| **Keep-Alive & LWT** | Heartbeat & Timeout (15s) | Providers send periodic heartbeats/data. If no message is received within 15 seconds, the broker marks the entity as offline. |
| **Command Routing** | `command` messages | Allows bi-directional messaging where subscribers or controllers send execution commands (e.g. `scram`, `activate`, `setBurnRate`) back to providers via the broker. |

---

## 🔄 Automatic OTA Updates & Commit Hash Versioning

`cc:mqtt` includes a built-in background **Auto-Updater** that continuously keeps all your in-game computers updated without manual intervention:

* **Automatic GitHub Sync**: Every 60 seconds (and on boot), each running script (`broker`, `provider`, `subscriber`, `controller`) queries the GitHub Commit API (`https://api.github.com/repos/PrimeAPI/cc-mqtt/commits/main`).
* **Zero-Touch Upgrades**: When a new commit is detected on `main`, the script automatically downloads the latest code from GitHub, replaces `startup.lua`, updates `.version`, and reboots the ComputerCraft computer.
* **Commit Hash Version Metric**:
  * Every entity reports its running Git commit hash (`v:a1b2c3d`) to the network.
  * The **Broker Terminal Browser**, **Broker Inspector**, **Controller**, and **Monitor Overview** display the short 7-character commit hash (`VER`) for every connected provider and subscriber.

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

### 4. `controller.lua` — Automation & Control Server
* **Role**: Evaluates triggers and automations across all connected network entities, executing remote actions automatically and displaying live rule status & audit logs on attached monitors.
* **Features**:
  * **Flexible Expression Engine**: Evaluates conditions and dynamic action arguments with built-in unit constants (`MFE/t`, `kFE/t`, `GFE/t`) and property proxies.
  * **Multiple Execution Modes**: Supports `edge` (trigger once on state change), `continuous` (dynamic proportional scaling), and `state` (then/else state transitions).
  * **Monitor Status & Audit Log**: Renders rule health badges (`[OK]`, `[TRIG]`, `[ACT]`, `[OFF]`, `[ERR]`) and a real-time scrolling audit log of invoked actions.
  * **Interactive Terminal TUI**:
    * `[Space]`: Toggle individual automation rules on/off.
    * `[T]`: Force test/trigger selected rule manually.
    * `[E]` / `[Enter]`: Inspect detailed rule conditions, actions, and evaluation errors.
    * `[Tab]`: Switch between Rules view and Monitored Entities telemetry state.

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

### 3. Automation Control Server Setup (`controller.lua`)
On a ComputerCraft computer equipped with a Wireless/Wired Modem and an attached Monitor:

```bash
wget https://raw.githubusercontent.com/PrimeAPI/cc-mqtt/refs/heads/main/controller.lua startup.lua
reboot
```

---

### 📱 Advanced Pocket Computer Tablet Setup (`tablet.lua`)
On an **Advanced Pocket Computer** (Tablet):

```bash
wget https://raw.githubusercontent.com/PrimeAPI/cc-mqtt/refs/heads/main/tablet.lua startup.lua
reboot
```

---

## 🖥️ Interactive Terminal TUIs & Features

### 📡 Broker Interactive TUI (`broker.lua`)
* **Live Network Overview**: Displays all registered providers, subscribers, and topics with short commit hashes (`VER`).
* **Entity Inspector**: Browse retained telemetry, view actions, and trigger entity commands.
* **Offline Entity Management**: Remove individual offline entities (`[D]`) or purge all offline entities (`[P]`).

### ⚙️ Provider Interactive TUI (`provider.lua`)
* **Real-time Countdown Timers**: Live countdown timers for `Push` (telemetry poll), `Announce` (rednet announce), and `Update` (GitHub auto-update).
* **Sensor Value Inspector**: Select any attached device to inspect current sensor values in real-time.
* **Action Simulator**: Select any peripheral action (e.g. `scram`, `setBurnRate`) and simulate triggering it locally with custom arguments as if sent over MQTT!
* **Immediate State Sync**: Simulated actions automatically publish updated sensor states to the broker immediately.

### 📊 Subscriber Interactive TUI (`subscriber.lua`)
* **Live Timer Subtitles**: Displays real-time countdown timers for `Draw` (monitor refresh), `Reg` (registry sync), `Sub` (topic re-subscribe), and `Update` (auto-update check).
* **Live Config Management**:
  * `[Space]`: Toggle entities **ENABLED** / **DISABLED** directly from the terminal without quitting!
  * `[A]` / `[Enter]`: Edit display aliases for entities on the fly.
  * `[S]`: Launch the visual monitor setup editor.

### 🤖 Automation Control Server (`controller.lua`)
* **Live Rule Management**:
  * `[Space]`: Toggle rules `[ON]` / `[OFF]`.
  * `[T]`: Instantly test/trigger a rule manually.
  * `[E]`: Inspect rule parameters, condition string, action lists, and last error trace.
  * `[Tab]`: View real-time monitored entity telemetry cache.
* **Monitor Display**:
  * Displays color-coded rule status badges (`[OK]`, `[TRIG]`, `[ACT]`, `[ERR]`, `[OFF]`) and execution counters (`x142`).
  * Live bottom section renders real-time action audit log entries (e.g. `[14:22:05] EnergyController-SPS->setMaxFlow(8540000000)`).

### 📱 Pocket Computer Controller & Dashboard (`tablet.lua`)
* **Touch-Optimized UI**: Designed specifically for the 26x20 resolution of Pocket Computers with a bottom touch tab bar:
  * `[Dash]`: Live metric cards and percentage gauges.
  * `[Act]`: One-touch quick action buttons (e.g. `[!] SCRAM REACTOR`).
  * `[Ent]`: All-entities browser with live values and action trigger prompts.
  * `[Cfg]`: In-app configuration manager.
* **Startup-Only Auto Update**: Checks GitHub commit version hash strictly on startup.
* **Flicker-Free Heartbeat Animation**: Header contains a smooth pulsing heartbeat indicator (`[O]`) that proves the loop is alive without screen flicker.
* **Dual Monitor & Terminal Rendering**: Runs full interactive management TUI on the computer terminal while driving high-performance visual dashboards on attached Monitors.

---

## ⚡ Automation Use Cases (`automations.cfg`)

`controller.lua` automatically generates an `automations.cfg` configuration file on boot. Below are example rules implemented out-of-the-box:

```lua
-- 1. Fission Reactor Emergency Safety Scram & Chat Alert
{
  id = "fission_scram_waste",
  name = "Fission Reactor Waste Emergency Scram",
  enabled = true,
  mode = "edge",
  condition = "fisionReactor.waste > 20 and fisionReactor.isActive()",
  actions = {
    { entity = "fisionReactor", action = "scram" },
    { entity = "chatbox", action = "chat", args = "REACTOR EMERGENCY-SHUTDOWN: Waste > 20%" }
  }
}

-- 2. Induction Matrix -> SPS Proportional Energy Flow Scaling
{
  id = "sps_energy_scaling",
  name = "Induction Matrix -> SPS Dynamic Energy Scaling",
  enabled = true,
  mode = "continuous",
  condition = "inductionmatrix.fillPercent > 10",
  actions = {
    { entity = "EnergyController-SPS", action = "setMaxFlow", args = "inductionmatrix.fillPercent * 100MFE/t" }
  },
  elseActions = {
    { entity = "EnergyController-SPS", action = "setMaxFlow", args = 0 }
  }
}

-- 3. Fissile Fuel Tank Level -> Energy Controller Flow Regulation
{
  id = "fuel_gen_flow_control",
  name = "Fissile Fuel Level -> Energy Controller Flow",
  enabled = true,
  mode = "continuous",
  condition = "tank-fissile-fuele.fillPercent < 25",
  actions = {
    { entity = "EnergyController-Fuel-Generation", action = "setMaxFlow", args = "5MFE/t" }
  },
  elseActions = {
    { entity = "EnergyController-Fuel-Generation", action = "setMaxFlow", args = "500kFE/t" }
  }
}
```

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

