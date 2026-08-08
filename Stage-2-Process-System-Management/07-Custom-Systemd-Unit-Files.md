# Custom systemd Unit Files: `[Unit]`/`[Service]`/`[Install]`, `Type=`, `Restart=`, `WantedBy=`

Writing a correct custom `.service` file — and knowing which directive controls what — is a core skill for running any long-lived process (app server, worker, exporter) under systemd instead of a fragile init script or `nohup`.

## Explanation

### Where custom units live

- `/etc/systemd/system/` — local, admin-created units (custom services go here). **Highest precedence.**
- `/run/systemd/system/` — runtime-only units, gone after reboot.
- `/usr/lib/systemd/system/` (or `/lib/systemd/system/`) — units installed by packages. Never edit these directly — use an **override** (`systemctl edit <unit>`) instead, which creates a drop-in in `/etc/systemd/system/<unit>.d/override.conf` that survives package upgrades.

### The three sections

**`[Unit]`** — metadata and dependency/ordering info, not specific to service type:
- `Description=` — free text, shown in `systemctl status`.
- `After=` / `Before=` — **ordering only**, does not imply a dependency (a unit can start `After=network.target` even if network.target never starts).
- `Requires=` — hard dependency; if the required unit fails, this unit is stopped too.
- `Wants=` — soft dependency; failure of the wanted unit doesn't stop this one. Preferred over `Requires=` for most cases (less brittle).
- `Conflicts=` — mutually exclusive units.

**`[Service]`** — how to actually run and manage the process:
- `Type=` — tells systemd how to determine "this service has started":
  - `simple` (default) — process started by `ExecStart=` IS the main process; considered started immediately.
  - `forking` — the process forks and the parent exits; systemd tracks the child (needs `PIDFile=` typically). Used for classic daemons.
  - `oneshot` — process is expected to exit; useful for setup scripts. Combine with `RemainAfterExit=yes` so `systemctl status` shows it as "active" after exit.
  - `notify` — process sends a `READY=1` message via `sd_notify()` when actually ready (used by apps compiled with libsystemd support).
  - `idle` — like simple but delays execution until all jobs are dispatched (avoids interleaving console output during boot).
  - `exec` — like simple, but systemd waits for the actual `execve()` to succeed before considering it started (catches "binary not found" earlier).
- `ExecStart=` — command to run. Must use an **absolute path**.
- `ExecStop=` / `ExecReload=` / `ExecStartPre=` / `ExecStartPost=` — lifecycle hooks.
- `Restart=` — `no` (default), `on-failure`, `on-abnormal`, `always`, `on-abort`. `on-failure` is the usual production choice (restarts on non-zero exit / signal / timeout, not on clean `systemctl stop`).
- `RestartSec=` — delay before restart attempt (avoid restart storms).
- `User=` / `Group=` — run as non-root (security best practice — never run app services as root).
- `WorkingDirectory=` — cwd for the process.
- `EnvironmentFile=` — load `KEY=value` pairs from a file (e.g., `/etc/myapp/env`).
- `TimeoutStartSec=` / `TimeoutStopSec=` — how long to wait before considering start/stop failed.

**`[Install]`** — only relevant to `enable`/`disable`, ignored by `start`/`stop`:
- `WantedBy=multi-user.target` — the standard target for services that should start on normal boot (roughly equivalent to old runlevel 3/5). Creates a symlink in `/etc/systemd/system/multi-user.target.wants/` when enabled.
- `WantedBy=graphical.target` — for services needing a GUI session.
- `RequiredBy=` — like `WantedBy` but a hard dependency.
- `Alias=` — alternate name(s) for the unit.

### Common gotchas

- Forgetting `[Install]` entirely — the unit runs fine with `systemctl start`, but `systemctl enable` fails with "unit has no installation config."
- Editing a unit file and forgetting `systemctl daemon-reload` — systemd keeps using the cached/old definition; `systemctl status` shows a stale warning about this.
- `Type=simple` for a process that forks internally — systemd loses track of the real process, `systemctl status` shows odd state, and `Restart=` may not behave correctly.
- Relative paths in `ExecStart=` — not allowed, must be absolute.
- Not setting `User=` — service runs as root by default, a security smell in reviews.
- `Restart=always` combined with a fast-crashing binary and no `RestartSec=`/`StartLimitBurst=` — can hammer the system in a restart loop; systemd's built-in rate limiting (`StartLimitIntervalSec=`, `StartLimitBurst=` in `[Unit]`) eventually marks it "failed" until reset.

## Hands-On Examples

**1. A minimal but production-reasonable custom service**
```bash
$ sudo tee /etc/systemd/system/myapp.service > /dev/null << 'EOF'
[Unit]
Description=MyApp backend API server
After=network.target

[Service]
Type=simple
User=myapp
Group=myapp
WorkingDirectory=/opt/myapp
EnvironmentFile=/etc/myapp/env
ExecStart=/opt/myapp/bin/myapp-server --config /etc/myapp/config.yml
Restart=on-failure
RestartSec=5
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target
EOF
```

**2. Reload systemd's cache and enable + start in one go**
```bash
$ sudo systemctl daemon-reload
$ sudo systemctl enable --now myapp.service
Created symlink /etc/systemd/system/multi-user.target.wants/myapp.service → /etc/systemd/system/myapp.service.

$ systemctl status myapp
● myapp.service - MyApp backend API server
     Loaded: loaded (/etc/systemd/system/myapp.service; enabled; vendor preset: enabled)
     Active: active (running) since Sat 2026-08-08 10:02:11 UTC; 4s ago
   Main PID: 18342 (myapp-server)
      Tasks: 6 (limit: 4678)
     Memory: 22.1M
        CPU: 180ms
     CGroup: /system.slice/myapp.service
             └─18342 /opt/myapp/bin/myapp-server --config /etc/myapp/config.yml
```

**3. Forgetting `daemon-reload` — the classic trap**
```bash
$ sudo vim /etc/systemd/system/myapp.service   # bump RestartSec to 10
$ sudo systemctl restart myapp
$ systemctl status myapp
Warning: The unit file, source configuration file or drop-in of myapp.service changed on disk.
Run 'systemctl daemon-reload' to reload units.
$ sudo systemctl daemon-reload
$ sudo systemctl restart myapp
```

**4. `Type=oneshot` for a setup/migration task**
```bash
$ sudo tee /etc/systemd/system/myapp-migrate.service > /dev/null << 'EOF'
[Unit]
Description=Run DB migrations for MyApp
Before=myapp.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/myapp/bin/migrate --up

[Install]
WantedBy=multi-user.target
EOF
$ sudo systemctl daemon-reload
$ sudo systemctl start myapp-migrate
$ systemctl status myapp-migrate --no-pager
     Active: active (exited) since Sat 2026-08-08 10:05:02 UTC; 2s ago
```
`active (exited)` — normal and expected for `oneshot` + `RemainAfterExit=yes`.

**5. Overriding a vendor unit safely instead of editing it directly**
```bash
$ sudo systemctl edit nginx.service
# opens $EDITOR on /etc/systemd/system/nginx.service.d/override.conf
[Service]
Restart=always
RestartSec=3

$ sudo systemctl daemon-reload
$ sudo systemctl cat nginx.service | tail -6
# shows the merged effective config, both vendor unit and override
```

**6. Testing `Restart=on-failure` behavior**
```bash
$ sudo systemctl start myapp
$ sudo kill -9 $(systemctl show -p MainPID --value myapp)
$ sleep 6
$ systemctl status myapp --no-pager | grep -E "Active|Main PID"
     Active: active (running) since Sat 2026-08-08 10:08:19 UTC; 1s ago
   Main PID: 19011 (myapp-server)
# PID changed and it's running again — systemd restarted it after RestartSec=5
```

**7. Checking why enable failed — missing `[Install]`**
```bash
$ sudo systemctl enable myapp-nowants.service
The unit files have no installation config (WantedBy=, RequiredBy=, Also=, or Alias=
settings in the [Install] section, and DefaultInstance= for template units).
This means they are not meant to be enabled using systemctl.
```

**8. Verifying the unit file syntax before deploying**
```bash
$ systemd-analyze verify /etc/systemd/system/myapp.service
# no output = no errors found

$ systemctl list-unit-files myapp.service
UNIT FILE       STATE    VENDOR PRESET
myapp.service   enabled  enabled
```

## Practice Questions

1. Write a `.service` unit for a Python worker at `/opt/worker/run.py` that runs as user `worker`, restarts on failure after 5 seconds, and starts on boot. Explain each directive you chose.
2. What's the practical difference between `Requires=` and `Wants=` in `[Unit]`? Why is `Wants=` usually the safer default?
3. Explain the difference between `After=` and `Requires=` — why does ordering alone not guarantee a dependency actually started successfully?
4. You edit `/etc/systemd/system/myapp.service` and run `systemctl restart myapp`, but the old behavior persists. What did you forget, and why does systemd behave this way?
5. What's the difference between `Type=simple` and `Type=forking`? What breaks if you use `Type=simple` for a daemon that internally forks and daemonizes?
6. You need to change one setting on a vendor-shipped unit (e.g., nginx.service) without it being overwritten on the next package upgrade. What command do you use, and what does it do under the hood?
7. What does `WantedBy=multi-user.target` actually do when you run `systemctl enable`? Where does the symlink get created?
8. A service keeps crash-looping and eventually systemd stops trying to restart it even with `Restart=always`. What mechanism causes this, and which two `[Unit]` directives control it?
9. Explain `RemainAfterExit=yes` — why is it needed for `Type=oneshot` services, and what does `systemctl status` show without it after the process exits?
10. How would you validate a unit file's syntax before deploying it to production, without actually starting the service?

## Interview Key Points

- `[Install]` only matters for `enable`/`disable` — a unit with no `[Install]` section can still be `start`ed manually but can't be enabled on boot; a very common "gotcha" question.
- `systemctl daemon-reload` is mandatory after any unit file edit — forgetting it is one of the most common real-world "why isn't my change taking effect" incidents.
- Know all `Type=` values cold, especially `simple` vs `forking` vs `oneshot` vs `notify` — and be able to say which one fits a given process's startup behavior.
- `After=` is ordering-only; `Requires=`/`Wants=` are dependency semantics. Conflating the two is a very common mistake that leads to race conditions on boot.
- `Restart=on-failure` (not `always`) is generally the right production default — `always` also restarts after a clean `systemctl stop`-triggered exit in some misconfigurations, and can mask genuine "should stay down" conditions.
- Never edit vendor unit files under `/usr/lib/systemd/system/` directly — use `systemctl edit` to create a drop-in override that survives package upgrades.
- `StartLimitIntervalSec=` / `StartLimitBurst=` (in `[Unit]`) cap restart attempts within a window — know this exists so `Restart=always` doesn't sound like an infinite-loop guarantee.
- Always run services as a dedicated non-root `User=`/`Group=` — running as root is a common security-review flag.
