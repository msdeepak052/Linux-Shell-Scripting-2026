# Shebang, Script Permissions & Execution

How the OS decides *what* runs your script and *whether* it's even allowed to.

## Explanation

Every executable text script starts with a **shebang** line: `#!/bin/bash` (or `#!/usr/bin/env bash`, `#!/bin/sh`, `#!/usr/bin/python3`, etc). This is not a comment being "ignored" — the kernel actively reads the first two bytes (`#!`) of the file and, if present, hands the rest of the line to the loader as the interpreter to invoke, passing the script's path as an argument to that interpreter.

Key mechanics:
- The shebang must be the **very first line**, first two characters must be `#!`, no blank line or space before it.
- If you run the script as `bash script.sh` or `sh script.sh`, the shebang is **ignored** — you're explicitly telling the shell which interpreter to use, so the kernel's `execve()` shebang-parsing path never triggers.
- If you run it as `./script.sh`, the kernel's loader reads the shebang and execs that interpreter. This requires the **execute (`x`) permission bit** on the file — read permission alone is not enough for `./script.sh` (though it is enough for `bash script.sh`, since there bash just *reads* the file).
- `#!/bin/bash` hardcodes bash's path. `#!/usr/bin/env bash` instead asks `env` to find `bash` via `$PATH` — more portable across systems where bash might live in `/usr/bin/bash`, `/usr/local/bin/bash`, etc. (common on macOS, some BSDs, Nix systems).
- No shebang at all + direct `./script.sh` execution → the kernel falls back to trying to exec the file as a binary, which fails for a text file. It errors out (typically `Exec format error`) unless the *current* shell (bash) detects it looks like a script and silently falls back to interpreting it with `/bin/sh` — behavior here is shell/OS dependent, so never rely on it.

## Hands-On Examples

**1. Create, permission-check, and run a basic script**
```bash
$ cat > hello.sh << 'EOF'
#!/bin/bash
echo "Hello, $(whoami) on $(hostname)"
EOF

$ ls -l hello.sh
-rw-r--r-- 1 deepak deepak 45 Aug  8 10:00 hello.sh

$ ./hello.sh
bash: ./hello.sh: Permission denied

$ chmod +x hello.sh
$ ls -l hello.sh
-rwxr-xr-x 1 deepak deepak 45 Aug  8 10:00 hello.sh

$ ./hello.sh
Hello, deepak on platform-01
```

**2. Read permission is enough when explicitly invoking the interpreter**
```bash
$ chmod -x hello.sh        # remove execute bit
$ ./hello.sh
bash: ./hello.sh: Permission denied

$ bash hello.sh            # works — bash just reads the file, no exec() needed
Hello, deepak on platform-01
```

**3. `#!/bin/bash` vs `#!/usr/bin/env bash`**
```bash
$ which bash
/usr/bin/bash

$ head -1 hello.sh
#!/bin/bash

# On a system where bash lives elsewhere (e.g. Homebrew on macOS: /opt/homebrew/bin/bash)
$ cat > portable.sh << 'EOF'
#!/usr/bin/env bash
echo "Bash version: $BASH_VERSION"
EOF
$ chmod +x portable.sh
$ ./portable.sh
Bash version: 5.2.21(1)-release
```

**4. What happens with no shebang**
```bash
$ cat > noshebang.sh << 'EOF'
echo "no shebang here"
EOF
$ chmod +x noshebang.sh
$ ./noshebang.sh
no shebang here          # bash fell back to interpreting it — DON'T rely on this

$ sh ./noshebang.sh       # some minimal shells (dash) are stricter, behavior varies
no shebang here
```

**5. Real-world pattern: a cron-safe script header**
```bash
$ cat > backup.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "Running from: $SCRIPT_DIR"
EOF
$ chmod +x backup.sh
$ ./backup.sh
Running from: /home/deepak/scripts
```
Cron jobs run with a minimal environment (often no `$PATH` entries you expect), so a correct shebang plus resolving your own script directory is a standard production pattern — never assume cron's working directory matches your interactive shell's.

## Practice Questions

1. You create `deploy.sh`, add a shebang, and run `./deploy.sh` — you get `Permission denied`. What's the fix, and why doesn't adding the shebang alone solve it?
2. What's the difference in behavior between running `bash script.sh` and `./script.sh` when the file has no execute permission?
3. Why might `#!/usr/bin/env bash` be preferred over `#!/bin/bash` in a script meant to run across multiple Linux distros and macOS?
4. A teammate's script works when they run `bash script.sh` but fails with `Exec format error` when others run `./script.sh`. What's the most likely cause?
5. You inherit a script with `#!/bin/sh` at the top but it uses bash-only syntax like `[[ ]]` and arrays. What will happen when it's executed via `./script.sh` on a system where `/bin/sh` is symlinked to `dash`, and how do you fix it?
6. Write a one-liner to find all `.sh` files under `/opt/scripts` that are **not** executable.
7. A cron job calling `/home/user/scripts/job.sh` fails with "command not found" for a tool that works fine interactively. What's the likely root cause, and how does the shebang/environment relate to it?
8. What does `chmod 750 script.sh` grant to owner, group, and others respectively, and would `./script.sh` work for someone in the group?
9. Explain why a script can have execute permission but still fail to run via `./script.sh` if the shebang path is wrong (e.g., `#!/bin/bash5` typo).
10. How would you make a Python script directly executable (`./tool.py`) the same way a bash script is, including the correct shebang line?

## Interview Key Points

- **Shebang ≠ execute permission** — they're two independent requirements for `./script.sh` to work; interviewers frequently test this exact distinction.
- Shebang is only consulted by the **kernel's loader** during `execve()` — i.e., only relevant for `./script.sh` or `/path/to/script.sh`, not `bash script.sh`.
- `#!/usr/bin/env bash` is the portable-path pattern; `#!/bin/bash` is the pinned-path pattern — know the trade-off (portability vs. determinism/security, since `env` searches `$PATH`).
- Minimum permission for `./script.sh`: **execute** bit for the invoking user's category (owner/group/other) is required; read isn't even strictly required for exec in some cases, but you do need read too in practice for interpreted scripts since the interpreter opens the file.
- Cron/systemd run scripts with a stripped-down environment — shebang + explicit `$PATH`/absolute paths inside the script are a common senior-level gotcha to mention.
- `chmod +x` vs `chmod 755` vs `chmod u+x` — know how to read/set permission bits both symbolically and octally.
