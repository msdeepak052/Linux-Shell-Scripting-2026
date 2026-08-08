# Shells Overview: bash vs sh vs zsh — What a Shell Actually Is

Before you write a single script, know exactly what program is interpreting your commands and why the choice isn't cosmetic.

## Explanation

A **shell** is a program that reads commands (interactively from a terminal, or from a script file) and executes them — it's the layer between you and the kernel's system calls. When you type `ls`, the shell parses that text, resolves `ls` against `$PATH`, and calls `fork()` + `execve()` to actually run it. The shell itself is just another userspace program — nothing magic — you can even run a shell from within a shell (`bash` inside `bash`).

Shells provide, beyond just "run this program": variable expansion, globbing (`*.log`), pipes/redirection (`|`, `>`, `<`), command history, job control (`&`, `fg`/`bg`), scripting constructs (`if`, `for`, functions), and tab completion (interactive shells only).

### The three shells, precisely

**`sh` — historically the Bourne shell**, the original Unix shell (1977, Stephen Bourne). On modern Linux, `/bin/sh` is almost never the actual historical Bourne shell binary — it's a **symlink** to some POSIX-compliant shell:
- On Debian/Ubuntu: `/bin/sh` → `dash` (Debian Almquist Shell) — small, fast, POSIX-strict, deliberately missing bash extensions.
- On RHEL/Fedora/SUSE: `/bin/sh` → `bash` running in POSIX-compatibility mode (bash detects it was invoked as `sh` and disables its own extensions).
- The **POSIX shell standard** defines the portable subset of syntax that `sh` guarantees — no arrays, no `[[ ]]`, no `local` in strict POSIX, no `function` keyword, no process substitution.

**`bash` — Bourne Again SHell**, GNU's 1989 extension of `sh`, and the de facto default interactive/scripting shell on virtually all Linux distros. Superset of POSIX `sh` syntax plus: arrays, `[[ ]]` test syntax, `(( ))` arithmetic, string manipulation (`${var//search/replace}`), process substitution (`<(...)`), here-strings (`<<<`), and much richer completion/history features.

**`zsh` — Z shell**, a bash-compatible-ish shell with dramatically more interactive features: superior tab-completion (context-aware, e.g. completing `git` subcommands), better globbing (`**` recursive glob natively, extended glob qualifiers), 179+ configurable options vs bash's ~27, plugin ecosystems (Oh My Zsh, Prezto), and per-directory/vcs-aware prompts. Since macOS Catalina (2019), `zsh` is the **default interactive shell on macOS** — this is the #1 reason engineers now encounter zsh daily even without choosing it.

### Interactive shell vs scripting shell — not the same axis

A shell can be used **interactively** (a human typing at a prompt, tab-completion and history matter) or **non-interactively/for scripting** (a `#!/bin/bash` script running unattended, features like fancy prompts and completion are irrelevant, but reliable deterministic syntax matters enormously). Your login shell (`$SHELL`, set in `/etc/passwd`) is your *interactive* default — a script's actual interpreter is whatever its shebang says, completely independent of your login shell. Running `zsh` interactively every day does not mean your scripts run under zsh unless their shebang explicitly says `#!/bin/zsh`.

### Which one should you actually use? (Decision rule)

| Context | Use | Why |
|---|---|---|
| **Writing production/automation scripts** meant to run on servers, in CI, in cron, in containers | **`#!/bin/bash`** (or `#!/usr/bin/env bash`) | Universally present on Linux servers, far richer syntax than POSIX `sh`, predictable/well-documented behavior, huge existing ecosystem of examples and tooling (`shellcheck` targets bash/sh dialects) |
| **Writing a script that must run in truly minimal environments** (Alpine-based containers, embedded systems, `/etc/init.d` scripts, `#!/bin/sh` explicitly required) | **POSIX `sh`** | `bash` may not even be installed (Alpine ships `ash`/BusyBox sh by default, not bash) — POSIX-only syntax guarantees portability |
| **Your personal interactive daily-driver terminal** | **Either bash or zsh — genuinely a matter of taste** | zsh's completion/plugin ecosystem is nicer for humans typing commands; bash is simpler and matches what you'll script in anyway, avoiding a mental-model mismatch |
| **You're on a Mac** | You'll be handed **zsh** as default interactive, but should still target **bash** for any script you write that might run on Linux servers | macOS default ≠ what your automation should assume; never let your local interactive shell dictate your shebang choice |

**Bottom line: for anything that runs unattended, automated, or on a remote server — always `#!/bin/bash` (or POSIX `sh` if you specifically need Alpine/embedded portability). zsh is a legitimate, even superior, choice for your own interactive terminal, but it is never the right shebang for a script other people or systems will run, because it isn't guaranteed to be installed.**

## Hands-On Examples

**1. Confirm what your login shell is vs what `/bin/sh` actually points to**
```bash
$ echo $SHELL
/bin/bash

$ ls -l /bin/sh
lrwxrwxrwx 1 root root 4 Jul  2 2023 /bin/sh -> dash

$ echo $0
bash
```
On Ubuntu, `/bin/sh` → `dash`; on RHEL/Rocky it's typically → `bash`. Never assume — always check on a new box.

**2. The same script behaves differently depending on which shell interprets it**
```bash
$ cat arraytest.sh
#!/bin/sh
arr=(one two three)
echo "${arr[1]}"

$ ./arraytest.sh
arraytest.sh: 2: arraytest.sh: arr=one two three: not found
# dash doesn't understand bash arrays — silent-ish failure with a confusing error

$ bash arraytest.sh
two
# same file, explicitly run with bash — works fine
```
This is exactly why the shebang matters more than what you happen to type at your interactive prompt — `./script.sh` uses whatever the shebang says, not your `$SHELL`.

**3. `[[ ]]` bash extension failing under strict `sh`**
```bash
$ cat check.sh
#!/bin/sh
if [[ -f /etc/hosts ]]; then
    echo "exists"
fi

$ ./check.sh
./check.sh: 3: [[: not found
```
`[[ ]]` is a bash (and zsh) keyword, not POSIX — under `dash` (Ubuntu's `/bin/sh`) it errors out immediately. Portable POSIX scripts must use `[ ]` instead.

**4. bash-only string manipulation not available in POSIX sh**
```bash
$ name="deploy.sh"
$ echo "${name%.sh}"     # bash parameter expansion — strip suffix
deploy

$ cat strip.sh
#!/bin/sh
name="deploy.sh"
echo "${name%.sh}"
$ dash strip.sh
deploy
```
Good news here: `${var%pattern}` suffix-stripping is actually POSIX-standard and works fine under `dash` too — but this is exactly the kind of thing you must verify per-feature rather than assume; not every bash "extension" is actually bash-exclusive.

**5. zsh's interactive superpowers — recursive globbing without `find`**
```bash
% ls **/*.log
logs/app/2026-08-01.log  logs/app/2026-08-02.log  logs/nginx/access.log  logs/nginx/error.log
```
Bash needs `shopt -s globstar` enabled first for `**` to recurse; zsh supports it natively out of the box — a commonly cited "why some people prefer zsh interactively" example.

**6. Checking which shells are installed and registered on a system**
```bash
$ cat /etc/shells
/bin/sh
/bin/bash
/usr/bin/bash
/bin/dash
/usr/bin/dash
/usr/bin/zsh

$ which bash sh zsh dash
/usr/bin/bash
/usr/bin/sh
/usr/bin/zsh
/usr/bin/dash
```
`/etc/shells` is the list of shells considered "valid login shells" (used by `chsh`, and checked by some daemons like FTP servers before allowing login).

**7. Real-world: a CI pipeline script fails on Alpine but works locally**
```bash
# Locally (Ubuntu, bash installed by default)
$ ./deploy.sh
Deploying to production...

# In Alpine-based CI container
$ ./deploy.sh
/bin/sh: ./deploy.sh: bash: not found
# because #!/bin/bash was used, but Alpine's base image doesn't ship bash by default —
# only ash (BusyBox's POSIX-ish sh) is present unless you explicitly `apk add bash`

$ cat deploy.sh | head -1
#!/bin/bash
```
This exact failure mode — a script that works on every dev's Ubuntu laptop but breaks in a minimal Alpine CI/prod container — is one of the most common real "shell portability" incidents in platform engineering. Fix: either `apk add bash` in the image, or rewrite the script to pure POSIX `sh` syntax.

**8. Changing your default interactive login shell**
```bash
$ chsh -s $(which zsh)
Password:
$ echo $SHELL
/usr/bin/zsh    # takes effect on next login session
```

## Practice Questions

1. What is a shell, technically — describe what happens between you typing `ls -la` and output appearing on screen.
2. What does `/bin/sh` actually point to on Ubuntu vs on RHEL, and why does that matter for script portability?
3. A script starts with `#!/bin/sh` but uses bash arrays and `[[ ]]`. What will happen when it's run as `./script.sh` on a Debian-family system, and how would you fix the script to actually be portable?
4. Explain the difference between your *login/interactive* shell (`$SHELL`) and the shell that actually executes a given script. Are they always the same?
5. Why might a CI pipeline script that works perfectly on an engineer's Ubuntu laptop fail with "bash: not found" inside an Alpine-based Docker build stage?
6. What are two or three concrete bash features that are NOT part of POSIX `sh` (and therefore unavailable in `dash`)?
7. If zsh is macOS's default shell since Catalina, why would a platform engineer still write `#!/bin/bash` (not `#!/bin/zsh`) for a deployment script authored on a Mac?
8. How would you check, without opening a text editor, what shell a given script will actually be interpreted by?
9. What's the practical difference between running `sh script.sh`, `bash script.sh`, and `./script.sh` when the script's shebang is `#!/bin/bash`?
10. Name one interactive feature zsh offers that bash doesn't have natively (without plugins/`shopt` tweaks), and explain why that feature matters more for interactive use than for scripting.

## Interview Key Points

- **`/bin/sh` is a symlink, not a distinct shell binary** — on Debian/Ubuntu it points to `dash`, on RHEL family typically to `bash` in POSIX mode. This single fact explains most "works on my machine" shell portability bugs and is a very commonly probed detail.
- **The shebang determines execution, not your login shell** — a huge number of candidates conflate "I use zsh interactively" with "my scripts run under zsh"; these are completely independent, and articulating that distinction clearly is a strong signal.
- Know concretely which features are **bash-only, not POSIX**: `[[ ]]`, arrays, `(( ))`, `${var//x/y}` substitution-with-replace-all, process substitution `<(...)`, here-strings `<<<` — these all break under strict `dash`/POSIX `sh`.
- **Alpine's minimal images don't ship bash by default** (only BusyBox `ash`) — this is a real, frequently-hit production/CI gotcha worth naming unprompted when discussing shell portability.
- macOS switching its default shell to zsh (Catalina, 2019) is *the* reason most engineers now touch zsh daily — know this history point, it comes up often as a "why does zsh matter" framing question.
- `chsh -s` changes your *login* shell; it has zero effect on which interpreter a script with an explicit shebang uses — don't conflate the two when explaining shell selection.
- Distinguish **interactive shell concerns** (completion, prompt, history, plugins — zsh's strengths) from **scripting concerns** (portability, determinism, tooling support — bash/POSIX sh's strengths) — a senior answer separates these two axes explicitly rather than treating "best shell" as one single ranking.
- `shellcheck` (static analysis tool) understands both bash and POSIX sh dialects and will flag bashisms in a `#!/bin/sh` script — worth mentioning as the practical tool for catching this class of bug before it reaches production.

Sources:
- [Difference between sh and bash - GeeksforGeeks](https://www.geeksforgeeks.org/computer-networks/difference-between-sh-and-bash/)
- [What's the Difference Between Bash, SH, and ZSH? - Medium](https://medium.com/@fulton_shaun/whats-the-difference-between-bash-sh-and-zsh-e10e5c55a574)
- [Zsh vs Bash: 7 Key Differences Tested (2026)](https://tech-insider.org/zsh-vs-bash-2026/)
- [Bash vs Zsh: A comparison of two command line shells](https://sunlightmedia.org/bash-vs-zsh/)
