# OpenCode One-Click Reset

`Reset-OpenCode.cmd` is the one-click entry point. It runs `Reset-OpenCode.ps1`,
which performs the reset in a fixed order:

1. **Stop** the bridge / oplire proxy / OpenCode background service.
2. **Repair config** (identity plugin, slash commands, state file).
3. **Check or rotate egress** (VPN/router change by default; WARP optional).
4. **Rotate the project identity** and clear stuck "free limit" errors.
5. **Zero token/context counters** for the current project (backup first).
6. **Restart** the OpenCode service.
7. **Verify** egress, identity, and the zeroed counters.

The default egress path is **external**: change your VPN, reconnect your router,
or switch to a hotspot. The script verifies that the IP actually changed since
the last run. It does not depend on Cloudflare WARP.

## Credits screen

Every run opens with an animated credits splash: a boot sequence, a glitch
reveal, block-letter `ABDULLAH FADIL`, a staged loading bar, and a credits
panel, then `>> starting reset`.

```
  [####################################] 100%  ready

  ==============================================================
    R E S E T E R
    opencode one-click reset
  ==============================================================

    MADE BY        ABDULLAH FADIL
    pipeline       7 stages, ordered
    token surgery  sqlite + wal, verified
    egress         identity + ip rotation
    safety         backup before every write

  ==============================================================

  >> starting reset
```

It only animates in a real console. Redirected output (pipes, logs, CI) gets a
single `RESETER | made by Abdullah Fadil` line instead, so automation stays
clean. Use `-NoSplash` to skip it even in a console.

## Quick start

Double-click:

```
Reset-OpenCode.cmd
```

With no arguments the launcher runs **interactive mode** — it asks y/n for each option:

```
Would you like to zero token/context counters? (y/n)
Wait for egress IP change (switch VPN/router now)? (y/n)
Use Cloudflare WARP instead of external IP change? (y/n)
Freeze counters at 0 after reset (old chat keeps working)? (y/n)
Run real-time loop counter-zeroing while chatting? (y/n)
Run live model check after reset (uses one message)? (y/n)
```

Just type `y` or `n` at each prompt. To skip prompts and use flags directly, run:

```
Reset-OpenCode.cmd -Wait -ZeroTokens
```

If you already changed the VPN before launching, the script notices the new IP
against the previous run and does not wait.
against the previous run and does not wait.

## Token/context zeroing

Token zeroing is **on by default**. It is a real database reset, not just a UI
refresh. Before writing, the helper makes a consistent backup of `opencode.db`
using SQLite's online backup API:

```
C:\Users\SSD\.local\share\opencode\opencode.db.backup-YYYYMMDD-HHMMSS\
```

It then zeroes:

- `session_v2.cost`
- `session_v2.tokens_input`
- `session_v2.tokens_output`
- `session_v2.tokens_reasoning`
- `session_v2.tokens_cache_read`
- `session_v2.tokens_cache_write`
- `cost` and `tokens` inside `session_message.data` for messages that carry
  usage metadata

The message **text, parts, titles, timestamps, and chat history stay intact**.
OpenCode calculates the "used context" ring from the last assistant message's
token metadata, so zeroing only `session_v2` would leave the ring unchanged.
Zeroing the per-message usage metadata is what makes the context display
actually reset. After the reset, the stored usage is `0`; the next prompt will
naturally add its own usage again because OpenCode still sends the existing
chat history. To keep the ring at `0`, start a new chat after resetting. If you
run the reset from inside a live chat, that chat's next turn will repopulate
the ring.

If OpenCode is running when the script is launched from inside it, the database
is updated live and the app should be reloaded to show `0`. For the full
service restart and stuck-error cleanup, launch `Reset-OpenCode.cmd` from
Explorer.

## Freeze mode: keep the old chat at 0

By default the counters climb again as soon as you keep chatting, because the
reset zeroes stored usage but OpenCode still sends the existing history. If you
want to keep the **same old chat and session** while the counter stays at `0`,
run:

```powershell
.\Reset-OpenCode.cmd -FreezeOnly
```

That starts a hidden Python helper. Every 3 seconds it re-zeroes the
`session_v2` totals and the `tokens`/`cost` metadata of messages in the selected
scope. The old chat keeps working normally; after a reload the context ring
reads `0` and stays there.

What it does **not** do:

- It does not shrink what is sent to the provider. The full history still goes
  out on every prompt, so real token consumption and any provider-side quota are
  unchanged. This is a local display and bookkeeping freeze, not a quota reset.
- It does not delete messages, parts, titles, or timestamps.
- It keeps writing to `opencode.db` every few seconds, so the WAL file grows a
  little and the app does extra reads while the helper runs.

Freeze modes:

```powershell
.\Reset-OpenCode.cmd -Wait -Freeze           # reset, then freeze
.\Reset-OpenCode.cmd -FreezeMinutes 30       # freeze for 30 minutes
.\Reset-OpenCode.cmd -Unfreeze               # stop freezing
.\Reset-OpenCode.cmd -FreezeOnly -ZeroAllSessions   # pin every session at 0
.\Reset-OpenCode.cmd -AutoCycle              # stop freeze -> wait IP -> reset -> freeze -> live check
.\Reset-OpenCode.cmd -Loop                   # start loop: re-zero counters every 30s, no service stop
.\Reset-OpenCode.cmd -Loop -LoopSeconds 60   # re-zero counters every minute
.\Reset-OpenCode.cmd -StopLoop               # stop the loop watcher
```

The full chain:

1. Stop any active freeze helper
2. Wait up to `-WaitSeconds` (default 120s) for the egress IP to change — switch your VPN/router/hotspot now
3. Rotate project identity
4. Zero token/context counters (backup first)
5. Restart OpenCode service
6. Re-freeze counters at 0 so the old chat stays at `0`
7. Run `opencode-unlimited test -live` to confirm the model unlimiter answers

Status is written to `%USERPROFILE%\.config\opencode\freeze-status.json`
(cycles, rows zeroed, last error), and the helper PID to `freeze.pid`. Both are
removed by `-Unfreeze`. A freeze started with `-FreezeMinutes` stops on its own
but leaves `freeze.pid` behind; `Test-FreezeRunning` treats that as inactive and
`-Unfreeze` cleans it up.

### Loop mode: real-time counter zeroing (the "keep it at 0" hook)

Loop mode is the lightweight alternative to a full reset. Instead of stopping
services, rotating identity, and restarting OpenCode every time, it starts a
hidden Python watcher that re-zeroes just the stored counters every N seconds:

```powershell
.\Reset-OpenCode.cmd -Loop           # re-zero every 30 seconds
.\Reset-OpenCode.cmd -Loop -LoopSeconds 60   # re-zero every minute
.\Reset-OpenCode.cmd -StopLoop       # stop the watcher
```

What it does:
- Writes `loop.pid` and `loop-status.json` to `%USERPROFILE%\.config\opencode\`
- Every interval seconds, zeros `session_v2` totals and per-message `tokens`/`cost`
- Does **not** stop the service, rotate identity, or restart OpenCode
- Does **not** delete messages, parts, titles, or timestamps

What it does **not** do:
- It does not change your egress IP or reset the provider-side quota
- It does not stop the "free limit" — that's server-side and tied to connection/IP
- It does not shrink what OpenCode sends to the provider

Use `-Loop` when you want the counter ring to stay at `0` in real time while you keep using the same chat. Use a full `-AutoCycle` (or `-Wait -Freeze`) when you actually need a new identity and egress.

### Why resetting does not stop the "free limit"

The limit that appears after a reset is server-side. Local counters, identity
rotation, and freeze mode cannot reset it. In practice:

- Rotating only the identity while the egress IP stays the same is easy for the
  provider to link, so a fresh identity can hit the limit immediately.
- The pasted `opencode-unlimited reset` runs only rotated the project id; they
  explicitly reported `database rows untouched` and `ip unchanged`, so nothing
  about the provider-side quota changed.
- A real egress change (different VPN server, router reconnect, hotspot) is the
  lever that matters. That is what `-Wait` watches for.

Freeze mode is the honest workaround for the *display*: it keeps the old chat
alive and the counter at `0`, while the reset pipeline handles identity and
egress.

### Command-line examples

```powershell
# Full reset, zero tokens, wait up to 2 minutes for a VPN/router change
.\Reset-OpenCode.ps1 -Wait

# Full reset, do not wait (identity/config only if the IP is unchanged)
.\Reset-OpenCode.ps1 -NoWait

# Rotate one project's database rows and zero its token counters
.\Reset-OpenCode.ps1 -Project "C:\dev\my-app" -Wait

# Zero every session's counters, not just this project
.\Reset-OpenCode.ps1 -ZeroAllSessions -Wait

# Keep the token/context counters
.\Reset-OpenCode.ps1 -NoZeroTokens -Wait

# Verify with a real message (costs one message)
.\Reset-OpenCode.ps1 -Wait -LiveTest

# Use Cloudflare WARP instead of a VPN/router
.\Reset-OpenCode.ps1 -Warp

# Use a proxy instead
.\Reset-OpenCode.ps1 -Proxy socks5://127.0.0.1:1080

# Preview only
.\Reset-OpenCode.ps1 -DryRun -Yes
```

## Options

| Option | Meaning |
|---|---|
| `-Wait` | Watch for the egress IP to change (default from the `.cmd` launcher). |
| `-WaitSeconds N` | Wait window in seconds. Default `120`. |
| `-NoWait` | Do not wait; verify only. |
| `-ZeroTokens` | Explicitly enable token/context zeroing (already on by default). |
| `-NoZeroTokens` | Keep the stored token/context counters. |
| `-ZeroAllSessions` | Zero every session in `opencode.db`, not just the selected project. |
| `-Freeze` | After the reset, keep the counters at 0 while you keep using the old chat. |
| `-FreezeOnly` | Start the freeze helper without running the rest of the reset. |
| `-FreezeMinutes N` | Freeze lifetime in minutes; default 0 = until `-Unfreeze`. |
| `-Unfreeze` | Stop the freeze helper. |
| `-AutoCycle` | One-shot chain: stop previous freeze, wait for IP change, reset, pin counters at 0, then run the live model check. |
| `-Loop` | Start a hidden background watcher that re-zeroes counters every N seconds (default 30) without service stop or identity rotation. |
| `-LoopSeconds N` | Interval between counter-zeroing passes in Loop mode. Default 30. |
| `-StopLoop` | Stop the running loop watcher. |
| `-Warp` | Rotate Cloudflare WARP: delete registration, register new, force `mode warp`, connect, verify. |
| `-SkipWarp` | Force external mode (kept for compatibility). |
| `-Proxy <url>` | Set `socks5://`, `socks5h://`, `http://` or `https://` upstream and skip WARP. |
| `-Direct` | Clear the configured proxy. |
| `-Project <path>` | Rotate that project's DB rows and zero that project's counters. |
| `-LiveTest` | Run `opencode-unlimited test -live` after the reset (one message). |
| `-NoServiceRestart` | Do not stop/start the OpenCode background service. |
| `-ForceInside` | Allow service/proxy restarts even when launched from inside OpenCode. |
| `-NoElevate` | Never prompt for UAC (WARP service restart fallback). |
| `-DryRun` | Print the plan and current state; change nothing. |
| `-Yes` | Skip the 3-second countdown. |
| `-NoSplash` | Skip the animated credits screen. |

Python 3 is required for the token/context reset. If it is unavailable, use
`-NoZeroTokens` to skip that step.

## Why not just run `oplire`?

The upstream repo (`BerkeOruc/oplire`) is a Rust tool, but:

- There is **no Windows release**; the winget manifest points to a missing asset
  and the repo has no releases.
- Its `reset` command uses Linux-only `sudo systemctl` and
  `/var/lib/cloudflare-warp`, so it cannot work on Windows.
- Its `quick-reset` reconnects WARP but does not force `mode warp`, so WARP can
  report **Connected** while the mode is `DnsOverHttps` / `DnsOverTls` and the
  traffic never enters the tunnel. That is exactly why the old reset kept
  reporting the same IP.

This script implements the working Windows path: it forces `mode warp` before
connecting, re-registers, and verifies the traced egress IP (`warp=on`).

## What "success" means

- `SUCCESS` - the egress IP changed (against the previous run or during the
  wait), a new project identity was written, and token zeroing was verified.
- `IDENTITY ONLY` - the identity and token reset are fresh, but the egress IP
  did not change. Switch VPN/router and rerun with `-Wait`.
- `FAILED` - the identity could not be rotated.
- `PARTIAL` - something unexpected happened, including a token-zeroing failure;
  check the log and the summary's `tokens/context` line.

The script writes a log to:

```
C:\Users\SSD\.config\opencode\resetter.log
```

## Safety notes

- Rotating the identity **does not delete sessions**. It rewrites the project id;
  `reset` also removes only the stored "out of messages" error rows.
- Token zeroing **does not delete chat history**. It only rewrites stored usage
  counters and the `tokens`/`cost` metadata inside message JSON.
- The DB backup is created before any token write. Each backup folder contains
  a `RESTORE.txt`. To restore: close OpenCode, delete the live
  `opencode.db-wal` / `opencode.db-shm`, copy the backup `opencode.db` over the
  live one, then start OpenCode.
- When run from Explorer, the script stops and restarts the OpenCode background
  service. When run from inside OpenCode, it uses identity-only mode so the
  current session survives; run the `.cmd` from Explorer for the full cleanup.
- `-Warp` deletes and recreates the WARP registration. On a free Cloudflare
  account this is fine; on a Teams/licensed account it may require re-enrollment.
- Using any of this may violate a provider's terms of service. You are
  responsible for how you use it.

## Troubleshooting

**The IP never changes.**
Use a different VPN server, reconnect the router, or use a phone hotspot. Some
VPNs assign the same IP on reconnect. Run `.\Reset-OpenCode.ps1 -Wait` and switch
while it watches.

**WARP says Connected but `warp=off` in the trace.**
Run `warp-cli mode warp` and reconnect. The script's `-Warp` mode does this
automatically, including an elevated service restart if needed.

**WARP Rotated & Connected but still "Free Limit" Appears Chat .**
Fix : Change Warp Connection to HTTP or TLS Whatever , Should be Working
, OpenCode Blocks VPN IPs Becouse They Exhausts The Free Limits Attempts

**The service did not come back.**
Run `opencode service start`. The script also retries once in its `finally`
block.

**Token zeroing failed.**
Close OpenCode fully and run `Reset-OpenCode.cmd` from Explorer. The helper
needs a short exclusive write window. Check the summary and the log; the backup
folder is printed before the write.

**Execution policy blocks the script.**
Use the `.cmd` launcher (it passes `-ExecutionPolicy Bypass`), or run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Reset-OpenCode.ps1 -Wait
```
