# 控制台、启动链与清单语义（FXServer 运维面）

从 shell 驱动本机服务器、资源清单变更何时生效、以及为什么 RCON 走不通。这些是"验证"
和"部署"共用的底座；正文只留结论，细节在这里。

## 驱动本机服务器

```bash
screen -dmS fivem bash -c 'cd <server-dir> && ./start.sh'      # start.sh may `exec`
scripts/fxserver_console.py "status"                            # send + read back the reply
scripts/fxserver_console.py -w 8 "restart custom-phone"
scripts/fxserver_console.py --page                              # current console page
```

`scripts/fxserver_console.py` (env `FXSERVER_SCREEN`, `FXSERVER_ENV_FILE`) wraps the three raw
calls — `stuff $'cmd\r'`, sleep, `hardcopy`, strip ANSI, return only the lines after the echoed
command:

```bash
screen -S fivem -p 0 -X stuff $'restart custom-phone\r'         # submit needs the \r
screen -S fivem -X hardcopy /tmp/console.txt                   # visible page only
```

- If `start.sh` ends in `exec`, a background process manager kills it on return — start it
  detached under `screen`.
- `stuff "restart x\n"` leaves the command typed but unsubmitted; send `$'restart x\r'`.
- **The echo is not evidence, in either direction — verify by effect.** The console mixes
  concurrent stdout into the input line, so a command that worked can echo as `vector2version`
  (or `randomitemsrestart qb-hud`) while executing correctly, and a command that did nothing can
  look clean. Treat the echo as decoration and confirm the *effect* instead: `restart <res>` must
  print `Stopping resource` **and** `Started resource`; after any restart re-check that the resource
  is actually running, because a bad line can leave it silently stopped (`Can't restart a stopped
  resource`).
- **The input line keeps residue, and nothing you send clears it.** DEL (`\177`, even ×200), Ctrl+U
  and a bare CR all failed; the residue then joins the next command. The only reliable move is to
  send one throwaway CR first — the console swallows whatever was pending as its own (unknown)
  line — and then send the real command. **That is not enough on its own**: residue can arrive
  *after* the CR (async stdout lands on the input line mid-injection) and join your command. Seen
  twice: `restart custom-director` → `randomitemsrestart custom-director`, and
  `restart custom-agent-client` → `rateLimiter_arrayUpdate_burstrestart custom-agent-client`, both
  leaving the resource **silently stopped**. So after any restart/stop confirm via
  `curl -s localhost:30120/info.json` (is it in `resources`?), never via the echo; and if a
  resource is already missing, do not rescue it command by command — restart the whole server
  (`screen -S <s> -X quit` → `fuser -k 30120/tcp` → start again). When a result must be
  trustworthy, skip the console entirely: put a start-time probe in the resource that writes the
  outcome with `SaveResourceFile` (see `verification.md`).
- **`TriggerClientEvent(..., source = 0, ...)` from a console call throws `native ...: Argument at
  index 1 was null`.** qb-core's own command wrapper does this for `missing_args` / permission
  failures, so an error naming `@qb-core/server/commands.lua` right after a console command is
  usually the framework notifying a non-existent player — fix your handler's nil guard, but do not
  chase the framework path as part of that fix.
- `hardcopy` captures the current screen, not scrollback — grep it right after the action you
  care about. `-X logfile` / `-X log on` applied to an already-created session can capture
  nothing (and a manual `log off` may not resume); treat the log file as a bonus, not the plan.
- **Probe a command channel before building on it.** A 200 from `/info.json` on the game TCP port
  proves only that an HTTP listener is there; send one real protocol packet
  (`--probe-rcon HOST PORT PASS`) and see whether it answers or closes. If it closes, drive the
  console through `screen` as above instead of writing an RCON client.
- **Console commands collide with the framework's chat commands.** A resource that calls
  `QBCore.Commands.Add('status', …)` shadows the console `status`, and handlers written for
  players index `GetPlayer(source)` unguarded — running it from the console executes the chat
  handler with `source = 0` and throws. When a console command errors in an unrelated resource,
  that is the cause; pick a different command, and nil-guard `source == 0` in the handler.
- Keep server command channels' credentials out of chat: have the user put the value in a
  `chmod 600` env file (read it with `getpass` so special characters survive) or grant a scoped
  `/etc/sudoers.d` NOPASSWD rule instead of storing a password at all. Adding the `source` line to
  `~/.bashrc` does **not** make those variables visible to agent tool calls (they run under
  non-interactive bash, and Ubuntu's `.profile` returns early when not interactive) — have each
  wrapper script read its own env file, and `source` it explicitly in ad-hoc commands. Verify with
  `bash -ic 'echo $VAR'` (works) vs a plain tool call (empty) before blaming the file.
- **"Configure passwordless sudo" is a hand-off, not a task you can do.** `sudo -n true` tells you
  in one call whether it is already in place; if it is not, never ask for the password in chat and
  never write it to a file. Emit one scoped line for the user to paste, then verify with
  `sudo -n <cmd>`:
  ```bash
  sudo bash -c 'printf "# agent ops: ufw only\n%s ALL=(root) NOPASSWD: /usr/sbin/ufw\n" "$USER" \
      > /etc/sudoers.d/<project>-ops && chmod 0440 /etc/sudoers.d/<project>-ops \
      && visudo -c -f /etc/sudoers.d/<project>-ops'
  ```
  Scope it to the binaries the work actually needs (`/usr/sbin/ufw`, a specific `systemctl` unit) —
  an `ALL=(ALL) NOPASSWD: ALL` line is the whole machine for the sake of one firewall rule. While
  waiting for the user, keep working on the parts that need no privilege instead of idling.
