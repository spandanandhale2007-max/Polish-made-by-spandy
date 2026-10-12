# Polish

A Windows tune-up and debloat tool that can undo itself.

Polish closes background apps that are wasting your RAM, trims what starts with
Windows, clears caches, removes Store bloat and tunes gaming, privacy and
interface settings. Every reversible change is written to a manifest first, so
one command puts everything back.

Works on Windows 10 and 11. Detects your hardware and only offers what applies.

---

## Run it

Open PowerShell **as administrator** and paste:

```powershell
irm https://raw.githubusercontent.com/spandanandhale2007-max/Polish-made-by-spandy/main/dist/Polish.ps1 | iex
```

That opens the window. Nothing happens until you click a button.

You don't strictly need administrator. Without it Polish still does most of its
work, but it can't create a system restore point and it skips the actions marked
`admin`. It tells you which ones instead of failing quietly.

### Prefer to download it?

Grab [`dist/Polish.ps1`](dist/Polish.ps1), then:

```powershell
powershell -ExecutionPolicy Bypass -File .\Polish.ps1
```

Downloading gets you the command line too, which the one-liner can't do because
`iex` has no way to pass arguments.

---

## OPTIMIZE NOW

The big button. One click, no restart, nothing deleted:

- closes idle launchers, updaters, overlays and tray apps
- frees physical RAM
- flushes the DNS cache
- makes sure Game Mode is on

It will **not** close anything with an open window, anything Windows needs, your
antivirus, or your chat and music apps. Those last ones are a separate tick box
because you might be in a call.

---

## Clearing the RAM cache

Windows keeps three separate pools people call "RAM cache", and Polish exposes
them separately because clearing each costs something different:

| Action | What it drops | Cost |
|---|---|---|
| `cache.ramlow` | Low-priority standby: speculative read-ahead Windows guessed you might want | Almost none. Start here. |
| `cache.ram` | The entire standby list | Everything re-reads from disk for a few minutes |
| `cache.rammodified` | Pages changed in RAM but not yet written to disk | A short disk burst. Loses nothing. |

Run `-Memory` first to see what you actually have. On a machine with 2.5 GB
sitting in standby, `cache.ram` returns about 2.2 GB of free physical RAM
immediately.

Standby is not wasted memory. Windows hands it back the instant a program asks
for memory, so a low "free" number with a high "cached" number is a healthy
machine, not a problem. The honest use for purging it is right before launching
a large game, a VM or a render, when you want the RAM free now rather than
negotiated mid-task. Running it on a loop just means reading from disk forever.

Both standby actions need administrator, because the kernel call behind them
requires `SeProfileSingleProcessPrivilege`.

---

## What's in it

| Module | What it covers |
|---|---|
| **Optimize** | Close background apps, free RAM, flush DNS, restart Explorer |
| **Gaming** | Game Mode, disable background recording, true fullscreen, mouse acceleration, GPU scheduling, power plan |
| **Startup** | Disable third-party startup programs and OEM nag tasks |
| **Caches** | RAM cache (standby list), GPU shader cache, temp files, Windows Update leftovers, browser caches, thumbnails, recycle bin |
| **Privacy** | Telemetry, advertising ID, targeted ads, activity history |
| **Features** | Copilot, Recall, Widgets, Bing results in Start, Edge nags |
| **Visual** | Instant interface response, transparency off |
| **Apps** | Remove Store bloat and manufacturer preinstalls |
| **Services** | Updater services to Manual, plus an honest report on the rest |
| **Maintenance** | Storage Sense, SSD TRIM, component store cleanup, system file repair |

Run `-List` to see everything that applies to your specific machine.

---

## Undo

Polish records every reversible change it makes:

```powershell
.\Polish.ps1 -Undo Last     # reverse the most recent run
.\Polish.ps1 -Undo List     # see every recorded run
```

Or click **Undo last run** in the window.

Reversal restores the exact previous value, including correctly *deleting* a
setting that didn't exist before rather than guessing a default.

Manifests live in `%LOCALAPPDATA%\Polish\runs`.

### What undo cannot do

Being straight with you, because a tool that overstates its undo is worse than
one with none:

- **Removed Store apps** have to come back from the Microsoft Store. Once the
  package payload is deleted there's no local copy to restore. Polish marks
  these actions `undo: Partial` and won't print a reinstall command it can't
  verify.
- **Deleted caches and temp files** are gone. That's the point of deleting them.
  Marked `undo: None`.
- **Closed apps** just need reopening. Marked `undo: None`.

Everything else, every registry value, service start type, scheduled task and
startup entry, is `undo: Full` and goes back exactly as it was.

Polish also creates a **system restore point** before its first change of a run,
when running as administrator, as a second line of defence.

---

## Safe by default

Open Polish and only fully reversible, no-restart actions are pre-ticked. You can
click OPTIMIZE NOW without reading anything and not hurt your machine.

Actions carry two labels, and the UI shows both:

| Risk | Meaning |
|---|---|
| **Safe** | Reversible, nothing you'd miss |
| **Moderate** | Removes or disables something you might actually want |
| **Advanced** | Could break a specific machine. Never pre-ticked. |

### What Polish refuses to do

These are hard-coded refusals, not unticked boxes:

- **Never removes** the Store, Settings, Windows Security, winget, Photos,
  Notepad, media codecs, shell components or sign-in packages. Removing Cortana
  packages has left people with a dead Start menu; the protect list exists so
  that class of mistake isn't reachable.
- **Never disables** your antivirus, Windows Update, or the services behind
  audio, networking and core Windows.
- **Never touches** OEM hotkey, touchpad, fan, thermal, power or lighting
  services. There is no reliable public list of which vendor services a given
  laptop model needs, and this is precisely where function keys and fan control
  break. Polish detects your manufacturer, protects anything matching those
  roles, reports the rest as *unknown risk*, and refuses to batch-disable them.
- **Never hides the cost of clearing the RAM cache.** Polish does have a standby
  list purge (`cache.ram`), because it is genuinely useful right before
  launching something that wants a lot of contiguous memory. But it tells you
  what you are paying: the standby list is file data held in RAM so Windows does
  not re-read it from disk, Windows already hands it back instantly when a
  program needs memory, and purging it means re-reading from disk for the next
  few minutes. It is never pre-ticked, and `cache.ramlow` offers the gentle
  version that drops only speculative read-ahead data.

---

## Command line

```powershell
.\Polish.ps1                                   # open the window
.\Polish.ps1 -List                             # every action for this machine
.\Polish.ps1 -Processes                         # what's running, what would close
.\Polish.ps1 -Memory                            # RAM breakdown: free vs cached

.\Polish.ps1 -Preset safe                       # all Safe, no-restart actions
.\Polish.ps1 -Preset recommend                  # Safe + Moderate
.\Polish.ps1 -Preset all                        # everything applicable

.\Polish.ps1 -Only optimize.closebg,optimize.trimram
.\Polish.ps1 -Only cache.ramlow                 # clear RAM cache, gentle
.\Polish.ps1 -Only cache.ram                    # clear RAM cache, everything
.\Polish.ps1 -Only Gaming,Privacy               # whole modules work too
.\Polish.ps1 -Preset safe -Skip cache.browser

.\Polish.ps1 -Preset recommend -DryRun          # show, change nothing
.\Polish.ps1 -Undo Last
```

Useful flags: `-DryRun`, `-Yes` (skip the confirm prompt), `-Quiet`,
`-NoRestorePoint`, `-NoElevate`.

**Always try `-DryRun` first.** It prints exactly what would happen and touches
nothing.

---

## A thing no software can fix

Polish reports your memory layout. If it says **SINGLE CHANNEL**, you have one
RAM stick in a board with more than one slot, and you're running at roughly half
your memory bandwidth.

Adding a second matching stick will do more for your machine than every option
in this tool combined. No optimizer can substitute for it, and any tool claiming
otherwise is lying to you.

---

## Logs

- Day logs: `%LOCALAPPDATA%\Polish\logs`
- Undo manifests: `%LOCALAPPDATA%\Polish\runs`

Last 30 of each are kept.

---

## Building

`dist/Polish.ps1` is generated. Edit `src/` and rebuild:

```powershell
powershell -ExecutionPolicy Bypass -File .\build\Build-SingleFile.ps1
```

The bundler refuses to build if any source file fails to parse, and verifies the
output parses before writing it.

```
Polish.ps1                  entry point, parameters, dispatch
src/Core/Detect.ps1         hardware, OS, OEM, GPU detection
src/Core/Safety.ps1         protect lists, restore point, undo manifest
src/Core/Engine.ps1         the Set-Polish* helpers that record undo
src/Core/Catalog.ps1        every action, declared with risk and reversibility
src/Modules/Processes.ps1   live process discovery and classification
src/Modules/Bloat.ps1       Store app and service discovery
src/Cli.ps1                 command line and run orchestration
src/UI/Window.ps1           the window (WPF)
build/Build-SingleFile.ps1  bundler
```

Adding an action means adding one entry to `Catalog.ps1`. As long as it only
calls the `Set-Polish*` helpers, undo is recorded automatically; the helpers read
the previous state as part of writing the new one, so an action physically can't
forget to record its own reversal.

---

## Honest limitations

- The window runs actions on the UI thread. It stays responsive and the log
  updates live, but it won't be draggable during the two slow actions (component
  store cleanup, system file repair), which say so on their labels.
- Polish is an unsigned PowerShell script. SmartScreen and some antivirus will
  flag it, same as every tool in this category. The source is here to read.
- Windows re-enables some of these settings on feature updates. Running Polish
  again re-asserts them and tells you what had drifted.

## Licence

MIT. Use it, fork it, ship it.
