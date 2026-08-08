# systemd Fundamentals: Units, Targets, `systemctl start/stop/enable/status`

systemd is PID 1 on virtually every modern distro — it's not just a service manager, it's the framework that controls boot order, dependency resolution, and process supervision, and `systemctl` is the interface you'll use daily as a platform engineer.

## Explanation

### systemd is PID 1, and everything is a "unit"

systemd replaces the older SysVinit as the first process the kernel starts (PID 1), and its core abstraction is the **unit** — a standardized description of something systemd manages. Unit types (by file extension):

| Unit type | Purpose |
|---|---|
| `.service` | A managed process (daemon/app) — the one you'll write and touch most |
| `.target` | A named synchronization point / grouping of other units (replaces SysVinit "runlevels") |
| `.timer` | Schedules another unit to run — the systemd alternative to cron |
| `.socket` | Socket-activated service (systemd listens on the socket, starts the service on first connection) |
| `.mount` / `.automount` | Filesystem mount points managed by systemd |
| `.path` | Triggers a unit when a watched file/directory changes |

### Targets vs runlevels

Old SysVinit had numbered runlevels (0=halt, 3=multi-user, 5=graphical, 6=reboot). systemd's `.target` units serve the same conceptual role but as named, composable groups — `multi-user.target` ≈ old runlevel 3, `graphical.target` ≈ runlevel 5, `reboot.target` ≈ runlevel 6. A target doesn't "do" anything itself — it's just a synchronization point that other units declare a dependency on (`WantedBy=multi-user.target` in a service's `[Install]` section means "start me when the system reaches multi-user mode").

### Unit file locations and precedence — a genuinely important detail

| Directory | Purpose | Precedence |
|---|---|---|
| `/usr/lib/systemd/system/` (or `/lib/systemd/system/`) | Units shipped by installed packages | Lowest |
| `/etc/systemd/system/` | Local admin overrides / custom units | **Highest — wins over package-provided units** |
| `/run/systemd/system/` | Runtime-generated units | Volatile, cleared on reboot |

This is why custom/overridden unit files always go in `/etc/systemd/system/` — it takes precedence over whatever the distro package installed, without you having to modify (and risk losing on upgrade) the package's own file.

### Core `systemctl` operations

```bash
systemctl start <unit>       # start now (does NOT persist across reboot)
systemctl stop <unit>        # stop now
systemctl restart <unit>     # stop then start
systemctl reload <unit>      # ask the service to reload config WITHOUT restarting (if it supports it)
systemctl status <unit>      # current state + recent log lines + cgroup process tree
systemctl enable <unit>      # create symlink so it starts on boot (does NOT start it now)
systemctl disable <unit>     # remove that symlink (does NOT stop it now)
systemctl enable --now <unit>   # enable AND start in one command
systemctl is-active <unit>   # prints active/inactive/failed, exit code reflects it
systemctl is-enabled <unit>  # prints enabled/disabled
systemctl daemon-reload      # re-read unit files after editing one — REQUIRED after any unit file change
```

### `start`/`stop` vs `enable`/`disable` — the classic confusion

These are **two independent axes**, not synonyms:
- **`start`/`stop`** — affects the **current running state**, right now, until reboot.
- **`enable`/`disable`** — affects whether it **starts automatically at boot**, via a symlink in a `.wants/` directory; has zero effect on whether it's running right now.

All four combinations are valid and meaningful: a service can be started-but-disabled (running now, won't survive reboot — common for manual/temporary testing), or enabled-but-stopped (will start next boot, not running now — e.g. right after `enable` without `--now`).

## Hands-On Examples

**1. Checking service status**
```bash
$ systemctl status nginx
● nginx.service - A high performance web server
     Loaded: loaded (/usr/lib/systemd/system/nginx.service; enabled; vendor preset: enabled)
     Active: active (running) since Thu 2026-08-06 08:02:11 UTC; 2 days ago
   Main PID: 1102 (nginx)
      Tasks: 3 (limit: 4678)
     Memory: 9.8M
        CPU: 1min 14.203s
     CGroup: /system.slice/nginx.service
             ├─1102 nginx: master process /usr/sbin/nginx
             └─1103 nginx: worker process
```

**2. `start` vs `enable` demonstrated separately**
```bash
$ systemctl enable myapp.service
Created symlink /etc/systemd/system/multi-user.target.wants/myapp.service → /etc/systemd/system/myapp.service
$ systemctl is-active myapp
inactive
$ # enabled for next boot, but NOT running right now
$ systemctl start myapp
$ systemctl is-active myapp
active
```

**3. `enable --now` — the common shortcut**
```bash
$ systemctl enable --now myapp.service
Created symlink /etc/systemd/system/multi-user.target.wants/myapp.service → /etc/systemd/system/myapp.service
$ systemctl is-active myapp
active
```

**4. `restart` vs `reload` — avoiding a hard drop of connections**
```bash
$ systemctl reload nginx
$ systemctl status nginx | grep Active
     Active: active (running) since Thu 2026-08-06 08:02:11 UTC; 2 days ago
$ # same start time, same PID, since= — nginx re-read config in place, no dropped connections

$ systemctl restart nginx
$ systemctl status nginx | grep Active
     Active: active (running) since Sat 2026-08-08 14:52:03 UTC; 3s ago
$ # new start time — full stop/start cycle happened
```

**5. Checking what `enabled` actually creates**
```bash
$ ls -l /etc/systemd/system/multi-user.target.wants/ | grep myapp
lrwxrwxrwx 1 root root 39 Aug  8 14:40 myapp.service -> /etc/systemd/system/myapp.service
$ systemctl disable myapp
Removed /etc/systemd/system/multi-user.target.wants/myapp.service
```

**6. `daemon-reload` — required after editing a unit file**
```bash
$ vim /etc/systemd/system/myapp.service   # change ExecStart path
$ systemctl restart myapp
$ systemctl status myapp | head -3
● myapp.service - My App
     Loaded: loaded (/etc/systemd/system/myapp.service; enabled)
$ # WRONG — systemd is still running with the OLD in-memory unit definition
$ systemctl daemon-reload
$ systemctl restart myapp
$ # NOW it picks up the edited ExecStart
```

**7. Listing units and finding failed ones — real triage command**
```bash
$ systemctl list-units --type=service --state=failed
  UNIT                LOAD   ACTIVE SUB    DESCRIPTION
● backup-sync.service loaded failed failed Nightly backup sync
1 loaded units listed.

$ systemctl status backup-sync.service
● backup-sync.service - Nightly backup sync
     Loaded: loaded (/etc/systemd/system/backup-sync.service; enabled)
     Active: failed (Result: exit-code) since Fri 2026-08-07 02:15:03 UTC; 1 day ago
    Process: 28810 ExecStart=/opt/scripts/backup_sync.sh (code=exited, status=1/FAILURE)
```

**8. Production incident: service crash-looping, diagnosing via targets and dependency chain**
```bash
$ systemctl status myapp
● myapp.service - My App
     Loaded: loaded (/etc/systemd/system/myapp.service; enabled)
     Active: activating (auto-restart) (Result: exit-code) since 14:58:02; 4s ago
    Process: 33210 ExecStart=/usr/bin/python3 /app/main.py (code=exited, status=1/FAILURE)

$ systemctl list-dependencies myapp.service
myapp.service
● ├─postgresql.service
● └─network-online.target

$ systemctl is-active postgresql
inactive
$ # root cause: myapp depends on postgresql, which is down — fix the dependency first, not myapp itself
$ systemctl start postgresql
$ systemctl restart myapp
$ systemctl is-active myapp
active
```

## Practice Questions

1. What's the difference between `systemctl start` and `systemctl enable`? Give a scenario where a service is enabled but NOT currently running.
2. Why does editing a `.service` file and running `systemctl restart` sometimes not pick up your changes, and what command fixes that?
3. What does `/etc/systemd/system/` take precedence over, and why is that the correct place to put custom or overriding unit files rather than editing files under `/usr/lib/systemd/system/`?
4. What's the difference between `systemctl restart` and `systemctl reload`? Why would you prefer `reload` for a web server handling live traffic?
5. Explain what a `.target` unit is and how it relates to old SysVinit runlevels. What does `WantedBy=multi-user.target` mean in a unit file?
6. Write the command to find all currently failed systemd services on a box, and then get more detail on why one specific one failed.
7. A service depends on PostgreSQL but keeps crash-looping on boot. What systemd command would show you its dependency chain, and how would you confirm the dependency itself is the root cause?
8. What's the difference between `systemctl is-active` and `systemctl is-enabled`? What exit codes do they return and why does that matter for scripting?
9. You disable a service with `systemctl disable myapp` while it's currently running. Is it still running afterward? What will happen on the next reboot?
10. What are the three main sections of a systemd unit file, and at a high level, what does each control (you'll go deeper on this in the next topic)?

## Real Interview Questions (Company-Attributed)

- "How will you restart an HTTP service running on a VM?" — asked at *Netcracker*

## Interview Key Points

- **`start`/`stop` control current runtime state; `enable`/`disable` control boot-time behavior — these are independent axes**, not synonyms; this is the single most-tested conceptual question in systemd basics.
- **`/etc/systemd/system/` overrides `/usr/lib/systemd/system/`** — always the right place for custom or admin-modified unit files so package upgrades don't clobber your changes.
- **Always run `systemctl daemon-reload` after creating or editing a unit file** — systemd caches parsed unit definitions in memory; forgetting this step is one of the most common "why isn't my change taking effect" mistakes, and a favorite interview gotcha.
- **`reload` vs `restart`**: reload asks the running process to re-read config in place (no dropped connections, same PID) if the service supports it; restart does a full stop/start cycle — know when each is appropriate (nginx/HAProxy config changes almost always want reload).
- Targets replaced SysVinit runlevels but are more flexible — they're just named synchronization/grouping points, not "special" units with inherent behavior; a unit becomes part of one via `WantedBy=` in its `[Install]` section.
- `systemctl enable --now` is the practical one-liner combining enable + start — worth knowing as the efficient real-world command instead of always doing two separate calls.
- `systemctl list-units --state=failed` (or `--type=service`) is the fast triage command for "what's broken on this box right now" — a strong answer to "how would you check overall system health" scenario questions.
- `systemctl status` output packs a lot in one screen: load path/enabled state, active state + duration, main PID, cgroup process tree, and recent log lines — know how to read all of it at a glance rather than just recognizing "active (running)."
