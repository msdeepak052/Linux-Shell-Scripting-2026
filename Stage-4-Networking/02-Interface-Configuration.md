# Interface Configuration: `ip addr`, `ip route`, `nmcli`, `netplan`, `nmtui`

Configuring, inspecting, and persisting network interfaces — and knowing which tool owns config on which distro family.

## Explanation

**The core split every senior engineer must internalize**: the `ip` command (iproute2) changes the **live kernel networking state** — instantly, but it's gone on reboot. Persisting config across reboots is owned by a **distro-specific configuration layer** that sits on top: **netplan** (Ubuntu 18.04+, generates config for a backend renderer) or **NetworkManager** directly (RHEL/Fedora/CentOS, and also usable on Ubuntu Desktop). Confusing "I ran `ip addr add` " with "I configured the interface" is one of the most common junior mistakes.

### `ip addr` / `ip link` / `ip route` — the live, in-kernel view

- `ip link show` — L2 view: interface names, MAC addresses, up/down state, MTU
- `ip addr show` (or `ip a`) — L3 view: IP addresses assigned to each interface
- `ip route show` (or `ip r`) — the kernel routing table: which interface/gateway traffic for a given destination goes through
- `ip addr add 10.0.1.50/24 dev eth0` — add an IP (temporary, lost on reboot/interface restart)
- `ip link set eth0 up` / `down` — bring an interface up/down
- `ip route add default via 10.0.1.1` — set a default gateway (temporary)

`ip` replaced the legacy `ifconfig`/`route`/`netstat` toolset (net-tools) years ago — `ifconfig` doesn't even show interfaces without an assigned IP by default and is often not installed on minimal images anymore. Always reach for `ip` first.

### Persistence layer 1: netplan (Ubuntu/Debian-family, 18.04+)

Netplan reads YAML files under `/etc/netplan/*.yaml` and generates the actual backend config for either `systemd-networkd` (servers, default) or `NetworkManager` (desktop). You edit YAML, then apply it — netplan itself doesn't run persistently, it's a generator.

```bash
sudo netplan apply     # generate + apply backend config from /etc/netplan/*.yaml
sudo netplan try       # apply with automatic rollback if you lose connectivity (safety net!)
sudo netplan generate  # just render config without applying, for validation
```
`netplan try` is a genuinely important production safety feature — it reverts automatically if you don't confirm within a timeout, protecting you from locking yourself out of a remote box with a bad config.

### Persistence layer 2: NetworkManager (`nmcli` / `nmtui`) — RHEL/Fedora/CentOS default

RHEL-family distros (and modern Ubuntu Desktop) manage persistent config through **NetworkManager**, either via the `nmcli` CLI (scriptable) or `nmtui` (interactive text UI, good for console/emergency access).

```bash
nmcli connection show                       # list all configured connections (profiles)
nmcli device status                         # show devices and which connection is active on each
nmcli connection add type ethernet con-name eth0-static ifname eth0 ip4 10.0.1.50/24 gw4 10.0.1.1
nmcli connection modify eth0-static ipv4.dns "8.8.8.8,1.1.1.1"
nmcli connection up eth0-static
nmtui                                        # interactive menu-driven equivalent
```
Unlike raw `ip` commands, `nmcli connection` changes are **persistent** — NetworkManager stores them as connection profiles (under `/etc/NetworkManager/system-connections/`) and reapplies them on boot/reconnect.

### Which one should you actually use? (Decision rule)

| Situation | Tool |
|---|---|
| Quick live/temporary change, debugging, scripting a one-off | `ip addr` / `ip route` (kernel-level, non-persistent) |
| Ubuntu/Debian **server** persistent config | **netplan** YAML → `netplan apply` |
| RHEL/CentOS/Fedora persistent config (server or desktop) | **nmcli** (scripted) or **nmtui** (interactive/console) |
| Ubuntu **Desktop** persistent config | Often NetworkManager under the hood too (netplan can target it as renderer) |
| No GUI, need interactive menu-driven fallback (e.g., after a lockout on console) | `nmtui` |

**Bottom line**: `ip` is for *live, temporary* changes and troubleshooting on any distro; for anything that must survive a reboot, use **netplan on Ubuntu/Debian servers** and **nmcli/nmtui on RHEL-family systems** — never hand-edit both layers at once, pick the one your distro's default networking stack owns or you'll fight config drift.

### Gotchas

- On Ubuntu Server, if `systemd-networkd` isn't the active renderer and you edit netplan YAML expecting `nmcli` to reflect it (or vice versa), you'll see stale/conflicting state — check `networkctl status` or `nmcli general status` to see which backend actually owns the interface.
- netplan YAML is **whitespace-sensitive** (it's YAML) — a bad indent silently produces a different (wrong) config or a parse error at `netplan apply` time.
- `ip addr add` is **additive** — running it twice with different IPs gives the interface two addresses; you often need `ip addr flush dev eth0` first if you meant to *replace* the address.

## Hands-On Examples

**1. Inspecting current interfaces and addresses**
```bash
$ ip addr show
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN
    inet 127.0.0.1/8 scope host lo
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP
    link/ether 02:42:ac:11:00:05 brd ff:ff:ff:ff:ff:ff
    inet 10.0.1.5/24 brd 10.0.1.255 scope global eth0
```

**2. Inspecting the routing table**
```bash
$ ip route show
default via 10.0.1.1 dev eth0 proto dhcp metric 100
10.0.1.0/24 dev eth0 proto kernel scope link src 10.0.1.5
169.254.0.0/16 dev eth0 scope link metric 1000
```
Read bottom-to-top-priority: the kernel matches the **most specific** route first (longest prefix match), falling back to `default` (the `0.0.0.0/0` route) if nothing else matches.

**3. Temporary IP assignment for quick testing (lost on reboot)**
```bash
$ sudo ip addr add 10.0.1.99/24 dev eth0
$ ip addr show eth0 | grep inet
    inet 10.0.1.5/24 brd 10.0.1.255 scope global eth0
    inet 10.0.1.99/24 scope global secondary eth0
$ sudo ip addr del 10.0.1.99/24 dev eth0    # remove it again
```

**4. Persistent static IP via netplan (Ubuntu Server)**
```bash
$ cat /etc/netplan/01-netcfg.yaml
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: no
      addresses: [10.0.1.50/24]
      routes:
        - to: default
          via: 10.0.1.1
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1]

$ sudo netplan try
Do you want to keep these settings?

Press ENTER before the timeout to accept the new configuration


Changes will revert in 110 seconds
$ [ENTER]
Configuration accepted.
```

**5. Persistent static IP via nmcli (RHEL/Fedora)**
```bash
$ sudo nmcli connection add type ethernet con-name eth0-static ifname eth0 \
    ipv4.method manual ipv4.addresses 10.0.1.50/24 ipv4.gateway 10.0.1.1 \
    ipv4.dns "8.8.8.8,1.1.1.1"
Connection 'eth0-static' (a1b2c3d4-e5f6-...) successfully added.

$ sudo nmcli connection up eth0-static
Connection successfully activated (D-Bus active path: /org/freedesktop/...)

$ nmcli device status
DEVICE  TYPE      STATE      CONNECTION
eth0    ethernet  connected  eth0-static
lo      loopback  unmanaged  --
```

**6. Diagnosing "server has no default route" (common real incident)**
```bash
$ curl -v https://api.example.com
* Could not resolve host / Network is unreachable

$ ip route show
10.0.1.0/24 dev eth0 proto kernel scope link src 10.0.1.5
# no "default via ..." line — that's the bug

$ sudo ip route add default via 10.0.1.1 dev eth0   # temporary fix
$ curl -sI https://api.example.com | head -1
HTTP/1.1 200 OK
```
Then make it permanent via netplan/nmcli — a raw `ip route add` fix will vanish on the next reboot, which is a classic "fixed it, but it broke again after a restart" postmortem.

**7. Bringing an interface down/up (e.g., after a driver hang)**
```bash
$ sudo ip link set eth0 down
$ sudo ip link set eth0 up
$ ip link show eth0 | head -1
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP
```

**8. `nmtui` for console/emergency recovery (no scripting, menu-driven)**
```bash
$ sudo nmtui
# Opens a text-based menu:
#   Edit a connection
#   Activate a connection
#   Set system hostname
# Useful when you're on a serial/iDRAC console with no X11 and don't
# want to hand-type a long nmcli command under pressure.
```

## Practice Questions

1. You run `ip addr add 10.0.1.99/24 dev eth0` and it works, but after a reboot the IP is gone. Why, and what's the correct fix on Ubuntu Server vs RHEL?
2. Explain the relationship between netplan and `systemd-networkd`/NetworkManager — is netplan itself a running service?
3. What does `ip route show` output tell you when there's no `default via ...` line, and how do you fix it (both temporarily and persistently)?
4. Walk through how you'd configure a static IP on an Ubuntu 22.04 server vs a RHEL 9 server — name the exact files/commands for each.
5. What's the practical difference between `ip addr add` and `ip addr replace`? When would using `add` twice bite you?
6. What does `netplan try` do differently from `netplan apply`, and why is that meaningful when you're configuring a remote server over SSH?
7. A coworker insists `ifconfig` is fine to use in 2026. What would you tell them about why `ip` is preferred, and one concrete example of something `ifconfig` doesn't show by default?
8. How would you determine, on an Ubuntu server, whether netplan is currently rendering to `systemd-networkd` or `NetworkManager` as its backend?
9. Write the `nmcli` command(s) to create a new persistent ethernet connection profile named `prod-eth0` with static IP `10.0.2.10/24`, gateway `10.0.2.1`, and DNS `1.1.1.1`.
10. Given `ip route show` output with two routes to the same destination network at different metrics, which one does the kernel actually use, and why?

## Interview Key Points

- **Live (`ip`) vs persistent (netplan/NetworkManager) is the single most-tested concept** — always state explicitly whether your fix survives a reboot.
- Know the **distro split cold**: Ubuntu/Debian servers → netplan YAML; RHEL/CentOS/Fedora → NetworkManager (`nmcli`/`nmtui`). This maps directly to the roadmap's "Debian vs RHEL family" emphasis.
- `netplan try` (auto-rollback on bad config) is a strong senior-level answer to "how do you safely change network config on a remote server without locking yourself out."
- `ip route show` and reading the routing table (longest-prefix-match, default route as the catch-all `0.0.0.0/0`) comes up in almost every "how does the kernel decide where to send a packet" question.
- Be able to explain **why `ip` replaced `ifconfig`/`route`/`netstat`** (net-tools is unmaintained, doesn't show all interfaces/IPv6 well, iproute2 is the modern standard) — a very common "do you know current tooling" filter question.
- `nmtui` is worth mentioning specifically for **console/out-of-band recovery scenarios** (broken SSH, serial console access) — shows practical incident-response awareness, not just command memorization.
- Netplan YAML indentation errors are a real, common failure mode — mention `netplan generate`/`netplan --debug apply` as how you'd validate before committing to `apply` on a remote box.
- `ip addr add` is additive (creates a "secondary" address), not a replace — know `ip addr flush dev <iface>` or `ip addr replace` as the fix when asked about duplicate/stale addresses on an interface.
