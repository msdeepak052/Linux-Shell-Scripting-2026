# Job Control: `jobs`, `fg`, `bg`, `&`, `nohup`, `disown`

Job control is how an interactive shell manages multiple running commands within one session — and knowing `nohup` vs `disown` is what separates "my SSH session dropped and killed my deploy" from a job that survives.

## Explanation

### Jobs are a shell-session concept

Every command your **interactive shell** launches is tracked as a "job" with a job number (`[1]`, `[2]`, ...), distinct from its PID. Job control (`jobs`, `fg`, `bg`, `Ctrl+Z`) only exists in interactive shells — it's a bash/shell feature layered on top of process/signal mechanics, not a kernel concept.

- **`command &`** — launch in the **background** immediately; shell prints `[job_number] PID` and returns the prompt right away.
- **`Ctrl+Z`** — suspend the **foreground** job (sends `SIGTSTP`), moving it to a stopped state without killing it.
- **`bg [%N]`** — resume a stopped job **in the background** (sends `SIGCONT`), prompt stays free.
- **`fg [%N]`** — bring a background or stopped job **to the foreground**, giving it the terminal and blocking the prompt until it finishes or is suspended again.
- **`jobs`** — list jobs in the current shell with their state (`Running`, `Stopped`, `Done`) and job number; `jobs -l` also shows PIDs.

Job references: `%1` (job number 1), `%+` or `%%` (the current/most recent job), `%-` (the previous job), `%name` (job whose command starts with "name").

### The SIGHUP problem — why background jobs still die

Backgrounding a job with `&` does **not** protect it from your terminal session closing. When a shell session ends (SSH disconnect, closing a terminal), it sends `SIGHUP` to all jobs still attached to it — foreground **and** background — unless something has explicitly detached them. This is the single most common "why did my job die when I disconnected" production mistake.

### `nohup` — ignore SIGHUP, decided at launch time

```bash
nohup command &
```
`nohup` makes the command **ignore SIGHUP** from the moment it starts, and by default redirects stdout/stderr to `nohup.out` (since the terminal that would have displayed them is going away). Must be applied **when starting** the command — you can't retroactively `nohup` something already running.

### `disown` — detach an already-running job from the shell

```bash
disown %1          # remove job 1 from this shell's job table
disown -h %1        # keep it in the job table, but mark it to NOT receive SIGHUP
disown -a           # disown all jobs
```
`disown` operates on jobs **already running in the current shell** — your escape hatch when you forgot `nohup` and can't restart the process. Plain `disown` removes the job from the shell's table entirely (you lose `fg`/`bg` control over it, and critically it will no longer be sent SIGHUP because the shell no longer tracks it as its job). `disown -h` is more surgical: keeps job control working but marks it to survive the shell's exit.

### Which one should you actually use? (Decision rule)

| Situation | Use | Why |
|---|---|---|
| Starting a long-running job and you know upfront you'll disconnect | **`nohup command &`** | Set-and-forget; ignores SIGHUP and preserves output to a file from the start |
| Job already running in foreground/background, you forgot `nohup`, and can't restart it | **`disown %N`** (after backgrounding it if it's in foreground: `Ctrl+Z` then `bg`) | The only way to retroactively protect a running job |
| You want the process to survive logout but might still want to reattach/monitor it later in the same session | **`disown -h %N`** | Keeps it in the job table for `fg`/`jobs` while still protecting it from SIGHUP |
| Long-running job you'll want to reattach to, inspect output live, or run multiple related commands in one persistent session | **`tmux`/`screen`** (outside pure job-control scope, but the real production answer) | Survives disconnects entirely and lets you reattach to a live interactive session, not just a backgrounded process |

**Bottom line: use `nohup` proactively when you know you're about to disconnect; use `disown` reactively when you forgot; use `tmux`/`screen` when you actually need to come back and interact with the session later, not just keep a process alive.**

## Hands-On Examples

**1. Basic background + `jobs`**
```bash
$ sleep 300 &
[1] 32601
$ jobs
[1]+  Running                 sleep 300 &
```

**2. Suspending and resuming with `Ctrl+Z`, `bg`, `fg`**
```bash
$ vim notes.txt
^Z
[1]+  Stopped                 vim notes.txt
$ jobs
[1]+  Stopped                 vim notes.txt
$ bg %1
[1]+ vim notes.txt &
$ fg %1
vim notes.txt
# back in vim, terminal blocked again until you exit or suspend it
```

**3. Multiple jobs, referencing by number**
```bash
$ sleep 500 &
[1] 32701
$ sleep 600 &
[2] 32720
$ ping -c 1000 8.8.8.8 > ping.log &
[3] 32744
$ jobs
[1]   Running                 sleep 500 &
[2]-  Running                 sleep 600 &
[3]+  Running                 ping -c 1000 8.8.8.8 > ping.log &
$ fg %2
sleep 600
^C
```

**4. The SIGHUP problem, demonstrated**
```bash
$ long_running_job.sh &
[1] 32800
$ exit      # closes the SSH session
# --- reconnect later ---
$ ssh myserver
$ ps -p 32800
    PID TTY          TIME CMD
$ # gone — SIGHUP killed it when the session closed, even though it was backgrounded
```

**5. `nohup` — the proactive fix**
```bash
$ nohup ./long_running_job.sh &
[1] 32850
nohup: ignoring input and appending output to 'nohup.out'
$ exit
# --- reconnect later ---
$ ssh myserver
$ ps -p 32850
    PID TTY          TIME CMD
  32850 ?        00:14:02 long_running_job.sh
$ tail -3 nohup.out
Processing batch 4102...
Processing batch 4103...
Processing batch 4104...
```

**6. `disown` — the reactive fix when you forgot `nohup`**
```bash
$ ./data_migration.sh &
[1] 32900
$ # oh no, I forgot nohup and need to disconnect
$ disown %1
$ jobs
$ # empty — shell no longer tracks it, so it won't send SIGHUP on exit
$ exit
# --- reconnect later ---
$ ssh myserver
$ ps -p 32900
    PID TTY          TIME CMD
  32900 ?        00:09:41 data_migration.sh
$ # survived — disown protected it retroactively
```

**7. `disown -h` — detach from SIGHUP but keep job control**
```bash
$ ./report_job.sh &
[1] 32950
$ disown -h %1
$ jobs
[1]+  Running                 ./report_job.sh &
$ # still visible/controllable in THIS shell session, but immune to SIGHUP if the shell exits
```

**8. Real deploy scenario: starting a background job, forgetting to detach, catching it before disconnecting**
```bash
$ ssh deploy@prod-app-03
$ ./deploy_release.sh v2.4.1 &
[1] 33010
$ jobs -l
[1]+ 33010 Running                 ./deploy_release.sh v2.4.1 &
$ # about to lose network — protect it NOW before disconnecting
$ disown -h %1
$ jobs
[1]+  Running                 ./deploy_release.sh v2.4.1 &
$ # connection drops mid-deploy — reconnect and verify it's still running
$ ssh deploy@prod-app-03
$ pgrep -fl deploy_release.sh
33010 deploy_release.sh v2.4.1
$ # survived the disconnect, deploy completed independently of the session
```

## Practice Questions

1. What's the difference between suspending a job with `Ctrl+Z` and killing it with `Ctrl+C`? What signal does each send?
2. You background a job with `&` and then close your terminal. Does the job survive? Why or why not?
3. What does `nohup` actually do, and why must it be applied when you START the command rather than after?
4. You forgot to use `nohup` on a long-running script that's already running in the background. What command lets you protect it retroactively, and how does it differ from `nohup`?
5. What's the difference between plain `disown %1` and `disown -h %1`?
6. Write the sequence of commands to: start `vim`, suspend it, list jobs, then resume it in the foreground.
7. You have three background jobs running. Write the command to bring job 2 to the foreground, and explain what `%+` and `%-` refer to in that context.
8. Where does `nohup`'s output go by default if you don't redirect it yourself, and why does that redirection happen at all?
9. Explain the actual mechanism: why does closing an SSH session send SIGHUP to jobs, and how does `disown` prevent that from affecting a specific job?
10. When would you reach for `tmux`/`screen` instead of just `nohup`/`disown`? What capability do they provide that pure job control doesn't?

## Interview Key Points

- **Backgrounding with `&` alone does NOT protect a process from session termination** — this is the single most important practical fact in this topic; SIGHUP is sent to background jobs too, not just foreground ones, when the shell session ends.
- **`nohup` is proactive (applied at launch), `disown` is reactive (applied to an already-running job)** — know exactly when you'd reach for each; this is a very common scenario-based interview question ("you forgot nohup, now what?").
- `nohup command &` redirects output to `nohup.out` by default if you don't redirect it yourself — worth knowing so you're not surprised by a mystery file after running it.
- `disown` (no flags) removes the job from the shell's job table entirely, losing `fg`/`bg` control over it; `disown -h` keeps it under job control while marking it immune to SIGHUP — know the distinction, it's a common follow-up question.
- Job control (`jobs`/`fg`/`bg`/`%N`) is a **shell-session-local** concept — it doesn't exist for a process once its owning shell exits or once it's disowned; don't confuse "job number" with PID, they're different identifiers.
- `Ctrl+Z` sends `SIGTSTP` (catchable, stops the process) — different from `Ctrl+C`'s `SIGINT` (catchable, requests termination) and very different from `SIGSTOP` (uncatchable) even though the *effect* of Ctrl+Z looks similar to SIGSTOP.
- For production long-running/detachable work, **`tmux`/`screen` is usually the better real answer** than pure `nohup`/`disown` because it lets you reattach to a live session and see ongoing output — mention this as the more senior-level answer when asked "how do you keep something running after you disconnect."
- Be ready to name the exact real-world failure mode: "I started a deploy/migration script in the background over SSH, my connection dropped, and the job died" — recognizing this as a missing-`nohup`/`disown` problem (not a networking problem) is exactly what this topic tests for.
