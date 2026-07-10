# 🚂 Train Station Monitor

> Zero-config live dashboard for your Factorio 2.0 rail network — auto-discovers every station, no circuit signals or combinators needed.

[![Factorio Version](https://img.shields.io/badge/Factorio-2.0%2B-orange)](https://mods.factorio.com/mod/train-station-monitor)
[![GitHub Release](https://img.shields.io/github/v/release/TheMaksoo/train-station-monitor?color=brightgreen)](https://github.com/TheMaksoo/train-station-monitor/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![GitHub Stars](https://img.shields.io/github/stars/TheMaksoo/train-station-monitor)](https://github.com/TheMaksoo/train-station-monitor/stargazers)

Place or remove a stop → the dashboard updates itself. No IDs, no signals, no combinators.

---

## ✨ Features

### 🎯 Core Dashboard
- 📡 **Zero-config auto-discovery** — every train stop tracked the moment it's built, removed, renamed, cloned, or revived
- 📊 **Live grouped view** — stations grouped by resource (item/fluid), showing load vs unload columns side by side
- 🔄 **Once-per-second refresh** — statistics and GUI repaint on `on_nth_tick(60)`, never per tick
- 🌙 **Matches vanilla UI** — uses base game styles, dark mode works automatically

### 🔍 Sorting & Filtering
- **Sort by**: least saturated · most saturated · most idle · alphabetical · station count · disabled first · resource name
- **Filter by**: load only · unload only · hide healthy · only queues · only disabled
- **Resource search** — type to filter by item/fluid name

### 📈 Analytics
- ⏱️ **Average wait time** per station (sampled over last 20 served trains)
- 📉 **Throughput graph** — trains served per minute over the last 10 minutes per resource group
- 🗺️ **Congestion heatmap** — opt-in map overlay: cool (trains flowing) → hot (starved), drawn via the Factorio rendering API

### ⚠️ Alerts
- 🚨 **No-provider alerts** — native Factorio alerts + dashboard badge when a resource has consumers but no available load station
- 🔕 **Providers-disabled alerts** — triggered when all load stations for a resource are disabled

### 🛠️ Per-Station Controls
- 📍 Zoom to station on the map
- 🚂 Open the assigned/next train
- ⚡ Enable / disable (sets train limit to 0 — no new trains dispatched)

---

## 🚀 Quick Start

### Install from Mod Portal
1. Search **Train Station Monitor** at [mods.factorio.com](https://mods.factorio.com/mod/train-station-monitor)
2. Click **Download** — Factorio installs it automatically
3. Enable in **Mods** and reload

### Install manually
```
train-station-monitor_0.1.0.zip  →  %APPDATA%\Factorio\mods\
```
The zip must contain a folder named `train-station-monitor_0.1.0` at the top level.

### Open the dashboard
- Click the **🚂 locomotive button** in the top-left mod-GUI area, **or**
- Press **Ctrl + T**

---

## 🏷️ Station naming convention

Name your stops with a rich-text icon tag followed by `Load` or `Unload`:

```
[img=item/iron-plate] Load
[img=item/iron-plate] Unload
[img=fluid/crude-oil] Load
[img=item/copper-plate] Unload #2
```

Both `/` and `=` separators work (`item/iron-plate` and `item=iron-plate` are identical). Stops without this pattern are silently ignored — depots and junction stops are not tracked.

---

## 🏗️ Architecture

Clean module separation — each file has exactly one responsibility. No cyclic dependencies. `events.lua` is the **only** place that calls `script.on_event`.

| Module | Responsibility |
|---|---|
| `control.lua` | Entry point — loads modules, calls `events.register()`. Nothing else. |
| `scripts/parser.lua` | **Pure**, stateless name parsing → `{kind, proto, mode, group_key}` |
| `scripts/cache.lua` | Owns the entire `storage` schema. All state access goes through here. |
| `scripts/discovery.lua` | Keeps cache in sync via events; one full scan on init only. |
| `scripts/statistics.lua` | Queue detection, saturation, enable/disable, average-wait. |
| `scripts/throughput.lua` | Trains-served-per-minute ring buffer (10-min window, per group). |
| `scripts/heatmap.lua` | Congestion map overlay — per-player, opt-in, rendering API. |
| `scripts/alerts.lua` | "No available provider" alerts — native Factorio + dashboard badge. |
| `scripts/rendering.lua` | Sort / filter logic + row widget construction (view only, no state). |
| `scripts/gui.lua` | Owns the button + window; builds, opens, refreshes, routes clicks. |
| `scripts/events.lua` | Single event-wiring hub. Defines the cadence. |

### ⚡ Performance model

- **Event filters** (`{type = "train-stop"}`) — the game only calls discovery handlers for train stops, not every entity
- **No per-tick scanning** — statistics run on `on_nth_tick(60)` (once per second)
- **One full scan ever** — on init / config-changed to back-fill pre-existing stops; after that it's pure event-driven cache maintenance
- **1000+ stations** stay cheap — O(1) per build/remove event, O(n) per second for the stats refresh

### 🔍 Queue detection (in order of reliability)

1. `entity.get_stopped_train()` — train physically at the platform → **present**
2. `entity.trains_count` — trains whose schedule targets this stop → dispatched / queued
3. `on_train_changed_state` feed — tags trains in `wait_station` state

`waiting = targeting − present`, bucketed to **0 / 1 / 2 / 3+**. The entire heuristic is isolated in one function.

---

## 📦 Tech Stack

| Layer | Technology |
|---|---|
| Language | Lua 5.2 (Factorio runtime) |
| Game API | Factorio 2.0 (`storage`, rendering objects, space platform events) |
| GUI | Vanilla Factorio styles (auto dark-mode) |
| State | `storage` (Factorio 2.0 — replaces `global`) |
| Events | Filtered `script.on_event` + `on_nth_tick` |

---

## 🔗 Links

- 🎮 [Mod Portal](https://mods.factorio.com/mod/train-station-monitor)
- 🌐 [solyx.gg](https://solyx.gg)
- 🐛 [Report an issue](https://github.com/TheMaksoo/train-station-monitor/issues)
- 📋 [Changelog](changelog.txt)

---

## 📄 License

MIT — see [LICENSE](LICENSE) for details.
