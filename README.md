```
 ██   ██  █████  ██   ██ ███████ ██       █████  ██████
 ██▒  ██▒██▒▒▒██ ███ ███▒██▒▒▒▒▒▒██▒     ██▒▒▒██ ██▒▒▒██
 ███████▒██▒  ██▒██▒█ ██▒█████   ██▒     ███████▒██████▒▒
 ██▒▒▒██▒██▒  ██▒██▒ ▒██▒██▒▒▒▒  ██▒     ██▒▒▒██▒██▒▒▒██
 ██▒  ██▒ █████▒▒██▒  ██▒███████ ███████ ██▒  ██▒██████▒▒
  ▒▒   ▒▒  ▒▒▒▒▒  ▒▒   ▒▒ ▒▒▒▒▒▒▒ ▒▒▒▒▒▒▒ ▒▒   ▒▒ ▒▒▒▒▒▒

              ░▒▓█ T U I █▓▒░
```

**A single-file PowerShell TUI for driving my homelab from Windows.**

Arrow keys, block-drawing borders, four themes, live server discovery. No modules, no package manager, no toolchain — one `.ps1` and the SSH client Windows already ships.

> ### ░▒▓ Read this first
>
> **This is a personal tool, not a product.** The server actions are wired to *my* box — my directory layout, my deploy flow, my conventions. Clone it and the menu will draw perfectly and then fail the moment you press Enter on anything, because the other half of this project lives on a server you don't have.
>
> It's public because the parts underneath are worth reading — the discovery code, the theming, the console-resize handling — and because what the server side assumes is documented below. Take the ideas, not the config.
>
> Which *tools* appear is configurable per server; what each one *runs* is not, on purpose.

---

## ░▒▓█ What it looks like █▓▒░

```
╔══════════════════════════════════════════════════════════════╗
║   ██   ██  █████  ██   ██ ███████ ██       █████  ██████     ║
║   ██▒  ██▒██▒▒▒██ ███ ███▒██▒▒▒▒▒▒██▒     ██▒▒▒██ ██▒▒▒██    ║
║   ███████▒██▒  ██▒██▒█ ██▒█████   ██▒     ███████▒██████▒▒   ║
║   ██▒▒▒██▒██▒  ██▒██▒ ▒██▒██▒▒▒▒  ██▒     ██▒▒▒██▒██▒▒▒██    ║
║   ██▒  ██▒ █████▒▒██▒  ██▒███████ ███████ ██▒  ██▒██████▒▒   ║
║    ▒▒   ▒▒  ▒▒▒▒▒  ▒▒   ▒▒ ▒▒▒▒▒▒▒ ▒▒▒▒▒▒▒ ▒▒   ▒▒ ▒▒▒▒▒▒    ║
║                       ░▒▓█ T U I █▓▒░                        ║
╚══════════════════════════════════════════════════════════════╝

┌──────────────────────────────────────────────────────────────┐
│  SERVERS │ THEMES                                            │
├──────────────────────────────────────────────────────────────┤
│██ [1] web                 192.168.1.10     █ ONLINE          │
│   [2] nas                 192.168.1.11     █ ONLINE          │
├──────────────────────────────────────────────────────────────┤
│   [ + ] Add             [ e ] Edit             [ - ] Delete  │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│ ▓ [Up/Dn] Move    [Tab] Tabs    [Enter] Select               │
│ ▓ [+] Add    [E] Edit    [-] Delete                          │
│ ▓ [R] Refresh    [PgUp/PgDn] Font    [Q] Quit                │
└──────────────────────────────────────────────────────────────┘
```

The banner is drawn character by character with an offset drop shadow — solid `█` in the title colour, `▒` in the shadow colour — so it re-tints instantly when you switch themes.

---

## ░▒▓█ Why it exists █▓▒░

Managing a couple of home servers means the same three things over and over: is it up, get me a shell, push the site. That's a `ping`, an `ssh`, and a `cd && git pull` — none of them hard, all of them requiring you to remember an IP and type the same line for the hundredth time.

This puts them behind arrow keys, and makes the answer to "is it up" visible before you ask.

---

## ░▒▓█ How it works █▓▒░

No framework. Everything is `Write-Host` with explicit colours, drawn into fixed-width boxes.

| Piece | How |
|---|---|
| **Layout** | Every row is composed from coloured segments and padded to a constant width, so borders always line up regardless of content. |
| **Banner** | A 5-row block font, rendered per-character so the letter and its drop shadow can take different colours. Runs of one colour are batched into a single write. |
| **Themes** | A table of `ConsoleColor` names. Switching one repaints from the same code path — there's no per-theme drawing logic. |
| **Font size** | P/Invokes `SetCurrentConsoleFontEx` to set Consolas at a chosen size, then fits the window to the art. Capped at whatever still shows the whole banner on your display. |
| **Status** | Async `Ping` with a short timeout, cached so arrowing around the menu doesn't re-ping. |
| **Discovery** | Three sources merged — `known_hosts`, the ARP cache, and an async port-22 sweep. |

### The btop problem

The menu window is deliberately narrow to frame the banner — narrower than the 80×24 that `btop` and most full-screen TUIs demand. So SSH and btop temporarily widen the console to 120×40 and restore it on exit. If the font is large enough that 80×25 physically won't fit on the display, it steps the font down for that session only and puts it back afterwards.

---

## ░▒▓█ Actions █▓▒░

Per server, under the `ACTIONS` tab. **These are the hardcoded, personal part.**

| Action | Runs | Assumes |
|---|---|---|
| **Connect (SSH)** | `ssh -t user@host` | Nothing beyond a reachable `sshd` |
| **Deploy site** | lists `/var/www/sites/*`, then `cd <picked> && git pull` | Sites live in that path, each one a git checkout with a remote |
| **Live stats (btop)** | `ssh -t user@host btop` | `btop` installed on the server |
| **Pi-hole** | submenu — status, live dashboard, web UI | a `pihole` container on the host |
| **Shutdown** | `sudo shutdown now`, behind a y/n confirm | Passwordless sudo, or you type a password |

Only the first is portable. The rest encode decisions I made on the server.

### Picking which tools a server gets

Not every box runs everything — a NAS has no site deploys and no Pi-hole. The **TOOLS**
tab on a server is a checklist of the five actions above:

```
┌──────────────────────────────────────────────────────────────┐
│  ACTIONS │ INFO │ TOOLS │ THEMES                             │
├──────────────────────────────────────────────────────────────┤
│   [█] Connect (SSH)         ssh                              │
│██ [ ] Deploy site           deploy                           │
│   [█] Live stats (btop)     btop                             │
│   [ ] Pi-hole               pihole                           │
│   [█] Shutdown              shutdown                         │
└──────────────────────────────────────────────────────────────┘
```

`Enter` or `Space` toggles, and the ACTIONS tab updates on the same keypress. It saves to
the server's `Tools` array in the config. **A server with no `Tools` key gets everything**,
so nothing has to be migrated.

---

## ░▒▓█ Pi-hole █▓▒░

The `Pi-hole` action opens a submenu with three things:

**Status** — one SSH round trip, roughly a second, straight into the panel:

```
┌──────────────────────────────────────────────────────────────┐
│  PI-HOLE STATUS                                              │
├──────────────────────────────────────────────────────────────┤
│   ▓ Blocking     : █ enabled                                 │
│   ▓ Queries      : 2,886                                     │
│   ▓ Blocked      : 1,167   40.4%                             │
│   ▓ Cached       : 1,115                                     │
│   ▓ Forwarded    : 586                                       │
│   ▓ Clients      : 10 active                                 │
│   ▓ Blocklist    : 93,516 domains                            │
│   ▓ Web UI       : http://192.168.1.10/admin                 │
└──────────────────────────────────────────────────────────────┘
```

**Live dashboard** — hands the terminal to `pihole-tui` on the server over `ssh -t`,
exactly the way the btop action works. See below.

**Open web UI in browser** — this one runs *locally*, not over SSH, so it genuinely
opens your browser via `Start-Process`. The dashboard on the server can't do that, so
it prints the URL in its footer instead.

### No password anywhere

Pi-hole v6's REST API returns `401` unauthenticated, and the usual answer is to mint an
app password and store it somewhere. That isn't necessary: the Pi-hole CLI ships its own
authenticated client, so

```bash
docker exec pihole pihole api stats/summary
```

returns the same JSON as the REST endpoint with no credential involved. Both the
PowerShell status panel and the Linux dashboard read through it. Nothing to store, nothing
to rotate, nothing to leak.

### The live dashboard

`pihole-tui/` in this repo — a btop-styled Python dashboard that runs on the server.

```
  pi-hole  ● blocking   queries 2,772   blocked 1,164   cached 1,022   on blocklist 93,516
╭─ queries — last 24h  red blocked · green allowed ──────────────────────────────────────────╮
│     ▂ ▂                                          ▂▇ █▄                                     │
│    ▆█ █ ▄       ▂▅ ▆ ▁                           ██ ██ ▃                                   │
│  ▃ ██ █ █▇ ▂ ▁▄ ██ █ █▁                        ▆ ██▁██ █ ▂     ▂ ▅ ▂                       │
│  █▁██▆█▄██ █ ██ ██▃█▂██            ▁         ▁ █▂█████▄█ █▆ ▄ ▇█ █ █▅            ▄ █ ▆▃    │
│ ▂█████████▆█▄██▇███████▁▃         ▆█▁█ ▃    ▂█▄█████████▇██▂█▂██▆█▆██ ▁         ▆█▄█▄██▁██ │
│ █████████████████████████▂     ▁▆▅████▇██▃▆▄███████████████████████████▁      ▃▄██████████ │
╰────────────────────────────────────────────────────────────────────────────────────────────╯
╭─ top blocked domains ───────────╮╭─ top clients ───────────────────╮╭─ block rate ─────────╮
│ ads.example-… █████████      42 ││ 192.168.1.31  █████████   2,420 ││      █████████       │
│ telemetry.ex… ████████─      40 ││ 192.168.1.42  ─────────     267 ││    █████████████     │
│ track.exampl… ████████─      40 ││ laptop        ─────────      57 ││  █████       █████   │
│ metrics.exam… ███──────      16 ││ nas           ─────────      16 ││  █████ 42.0% █████   │
│ beacon.examp… ███──────      15 ││ localhost     ─────────      10 ││  █████blocked█████   │
│                                 ││                                 ││    █████████████     │
│                                 ││                                 ││      █████████       │
│                                 ││                                 ││                      │
│                                 ││                                 ││   █ 1,164 blocked    │
│                                 ││                                 ││   █ 1,608 allowed    │
╰─────────────────────────────────╯╰─────────────────────────────────╯╰──────────────────────╯
  q quit  r refresh  p pause     web ui http://192.168.1.10/admin  (open on your own machine)
```

- **24h query graph** — 145 ten-minute buckets from `/api/history`, downsampled to the
  terminal width and drawn as stacked columns: blocked in red at the bottom, allowed in
  green above. Partial block glyphs (`▁▂▃▄▅▆▇`) give sub-cell resolution.
- **Block-rate ring** — a real donut, drawn per character cell from the angle and radius,
  with the percentage punched through the middle.
- **Top blocked domains / top clients** — ranked meters with a cool-to-hot gradient.
- **Tiered refresh** — summary and history every 2s, the top lists every 10s. Each
  `docker exec` costs ~160ms, so the calls are issued concurrently.
- `q` quits, `r` forces a refresh, `p` pauses.

Install it on the server:

```bash
scp -r pihole-tui you@192.168.1.10:~/src/
ssh you@192.168.1.10 'bash ~/src/pihole-tui/install.sh'
```

It needs `python3` and `python3-rich`, both of which Ubuntu already had. **No venv** —
Ubuntu's python3.14 ships without `ensurepip`, so `python3 -m venv` fails unless you
`sudo apt install python3.14-venv`, and there's nothing to gain from it when the distro
already packages the one dependency.

---

## ░▒▓█ The server side █▓▒░

The half of this project that isn't in this repo. Roughly what the target box looks like:

- **OS** — Ubuntu, OpenSSH 10.x
- **Web root** — sites as individual git checkouts under `/var/www/sites/<name>`, served by nginx
- **Deploys** — `git pull` in place; no build step, no restart
- **Auth** — ed25519 key from the Windows box, no password login
- **sudo** — permitted for shutdown
- **Extras** — `btop` installed for the live-stats action

> **Fill this in properly.** Anyone reading the repo learns more from an accurate version of this section than from the script itself — it's the part that can't be inferred from the code.

---

## ░▒▓█ Requirements █▓▒░

| | |
|---|---|
| **Windows PowerShell 5.1** | The one in `System32`. Uses `Add-Type` P/Invoke for console font control. |
| **The classic console host** | Font and window sizing call `SetCurrentConsoleFontEx`, which Windows Terminal ignores. It still runs there — sizing is just a no-op. |
| **OpenSSH client on PATH** | Already present on Win10 1809+, otherwise `Settings → Apps → Optional Features`. |
| **Key-based SSH auth** | Strongly recommended. Passwords work, but you'll type one per action. |

---

## ░▒▓█ Running it █▓▒░

```bat
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "path\to\Homelab-tui.ps1"
```

**Shortcut:** right-click → New → Shortcut, use that as the target, set *Start in* to the script's folder.

- **Quote the script path.** If it contains spaces and isn't quoted, PowerShell reads it as several arguments and dies instantly with no message.
- **Leave `-NoExit` off** so the window closes on `Q`. Add it back temporarily if you need to read a startup error before the window disappears.
- `-NoProfile` stops your PowerShell profile printing over the banner, and it launches faster.

---

## ░▒▓█ Keys █▓▒░

| Key | Does |
|---|---|
| `↑` `↓` | Move |
| `←` `→` | Switch tab — or pick between `[ + ]` and `[ - ]` when the action row is selected |
| `Tab` | Switch tab |
| `Enter` | Select / run |
| `+` `E` `-` | Add / edit / delete a server |
| `T` | Cycle theme without leaving the current screen |
| `R` | Re-ping every server |
| `PgUp` `PgDn` | Font size (also `]` and `[`) |
| `B` / `Esc` | Back |
| `Q` | Quit |

---

## ░▒▓█ Servers and discovery █▓▒░

No server is hardcoded. `[ + ]` opens a discovery panel that pulls candidates from three places, cheapest first:

| Source | Cost | Finds |
|---|---|---|
| `~/.ssh/known_hosts` | instant | anything this PC has SSH'd to before, powered on or not |
| ARP cache | instant | devices seen on the LAN recently |
| Port-22 sweep | ~1s | everything else, including a NAS you just plugged in |

Hosts with SSH open sort to the top and show their banner, so a real server is distinguishable from a printer that happens to have 22 open:

```
┌──────────────────────────────────────────────────────────────┐
│  ADD SERVER                                                  │
├──────────────────────────────────────────────────────────────┤
│██ 192.168.1.11    arp         SSH-2.0-OpenSSH_9.2p1          │
│   192.168.1.10    known_hosts already added                  │
│   192.168.1.1     arp         no ssh                         │
└──────────────────────────────────────────────────────────────┘
```

Pick one, give it a name and an SSH user, done. `[M]` enters an address by hand for anything off-LAN or on a non-standard port. `[R]` rescans.

`[ e ]` edits an existing entry — name, address and user, with the current values as defaults, so `Enter` keeps what's already there.

`[ - ]` removes an entry **from the list only** — it never touches the machine.

`Esc` backs out of any prompt in these flows without writing anything.

The sweep is async (`BeginConnect`, all 254 fired at once, one wait) — about 800 ms for a `/24`. Doing the same with `Test-NetConnection` would take several minutes. It only scans the interface holding the default gateway, so virtual adapters (VirtualBox `192.168.56.x`, Hyper-V, WSL) are skipped.

---

## ░▒▓█ Config █▓▒░

Settings live in `homelab-tui.config.json` beside the script, written on change and on quit:

```json
{
    "Theme": "Dark",
    "FontSize": 30,
    "Servers": [
        { "Name": "web", "IP": "192.168.1.10", "User": "you" }
    ]
}
```

**This file is gitignored** — it holds your addresses and SSH usernames. `homelab-tui.config.example.json` is the committed stub.

Three optional per-server keys:

| Key | Default | Use it when |
|---|---|---|
| `PiholeContainer` | `pihole` | your container is named something else |
| `PiholePort` | auto-detected via `docker port` | detection can't run, or you front it with a reverse proxy |
| `Tools` | all of them | you want a server to show only some actions — set from the TOOLS tab |

Neither is normally needed — the port is read from docker at runtime, so nothing about
your network is baked into the source.

Edit by hand if you prefer. A missing or malformed file is ignored and defaults are used, so deleting it is always a safe reset.

---

## ░▒▓█ Themes █▓▒░

`Dark` · `Matrix` · `Synthwave` · `Light`

Available as a tab from the server list *and* from inside any server, so it's never more than one keypress away. Moving the selection applies the theme live, and each row previews its own palette in the swatch column.

Add one by dropping an entry into `$Global:Themes` and its name into `$Global:ThemeNames`. Values are `ConsoleColor` names.

---

## ░▒▓█ Making it yours █▓▒░

The commands aren't configurable, but they are all in one place. Near the top of
`Homelab-tui.ps1`, under a header you can't miss:

```powershell
$Global:Cmd = @{
    Btop      = "btop"                     # whatever your live-stats tool is
    SitesDir  = "/var/www/sites"           # one directory holding site checkouts
    Deploy    = "cd {0} && git pull"       # {0} = SitesDir/<the site you picked>
    Shutdown  = "sudo shutdown now"
    PiholeTui = "~/.local/bin/pihole-tui"  # installed by pihole-tui/install.sh
    Pihole    = "pihole"                   # docker container name
}
```

That's every assumption this tool makes about a server. Point them at your own layout and
the rest of the file doesn't care — it's UI and knows nothing about what the commands are.
Want a build step in the deploy? `Deploy = "cd {0} && git pull && npm ci && npm run build"`.

**To add a whole new action**, there are exactly two places:

1. An entry in `$Global:ToolCatalog` — a `Key` and a `Label`.
2. A case in the `switch` in `Show-ServerScreen`, matched on that `Key`.

It then shows up in the TOOLS checklist for free, per server, and persists to the config
with no further work. The dispatch matches on `Key` rather than the display label
specifically so renaming a label can't silently break it.

The Pi-hole dashboard is a separate concern — it's a standalone Python file under
`pihole-tui/` that only needs `docker exec <container> pihole api` to work, so it'll run
against any Pi-hole v6 host without touching the PowerShell side at all.

---

## ░▒▓█ On not generalising this █▓▒░

An earlier draft of this README planned to move every action's command into the config, so
the tool became a generic *menu of SSH commands per server* and my commands became my
config. It would have worked, and I decided against it.

The reason is that the commands were never the hard part. `/var/www/sites/<name>` exists
because I made it exist; `git pull` deploys because I set the remotes up that way; the
Pi-hole panel works because there's a container called `pihole` on that box. Making the
*strings* configurable would not give anyone else a working tool — it would just move my
assumptions from the script into a file, and add a config schema to maintain in exchange
for nothing I need.

So: **the commands stay hardcoded, and the only rule is that nothing personal lands in the
repo.** Addresses, usernames and ports live in the gitignored config or are detected at
runtime. Which tools a server offers is a real setting because I genuinely need it — my
NAS runs neither the deploys nor Pi-hole. Everything else is welded in on purpose.

## ░▒▓█ Notes █▓▒░

**The script is UTF-8 with a BOM and must stay that way.** PowerShell 5.1 reads a BOM-less UTF-8 file as ANSI, which turns every box-drawing character into mojibake. `.gitattributes` pins this; if your editor strips BOMs, the banner is the first thing to break.

**Status is ping-only.** A host answering ICMP can still have `sshd` down. Results are cached — `R` forces a refresh.

**The sweep assumes a `/24`.** Fine for a home LAN, wrong for anything else.

---

## ░▒▓█ Limitations █▓▒░

- Port 22 only — no per-server SSH port or identity file
- What each action runs is hardcoded — deliberately, see below. Which actions a server shows is configurable
- The Pi-hole dashboard assumes a container named `pihole` on the same host
- No reboot action, no Docker controls
- The `INFO` tab shows the config entry, not live facts from the host
- No output history — once a command scrolls past, it's gone
- Windows only, and really conhost only
