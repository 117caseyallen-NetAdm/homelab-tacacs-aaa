# Build notes

Twelve phases, one device at a time. Each ends with the check that proved it.
The order was chosen so that a mistake at any step could lock out at most one
device, and only after a rescue session was already open on it.

---

## 0 — Prerequisites

AD groups `NetAdmins` and `NetOps`. Service accounts `svc-tacacs` (the LDAP
bind account) and `svc-oxidized` (the backup account, in `NetOps`). The admin
user in `NetAdmins`.

**Check:** the accounts exist and bind. The PA-440's service route was
confirmed at this stage too: the firewall's management plane sources its own
traffic separately from the dataplane.

## 1 — The container

An unprivileged Debian LXC, `CA-TAC-LAB`, at `10.99.20.32` on the management
VLAN — the network every device's management traffic already uses.

**Check:** `10.99.10.1` (the remote site's switch) answered at **TTL 252**,
three hops across the IPsec tunnel. That proved the cross-site path to the
server before any device was configured to depend on it.

## 2 — Build `tac_plus-ng` from source

[event-driven-servers](https://github.com/MarcJHuber/event-driven-servers),
built with PCRE2 and OpenSSL. It was chosen over Debian's `tacacs+` package
because that one authenticates through PAM, which can't return group
membership. Group membership is the whole authorization model here.

**Check:** `mavis_tacplus-ng_ldap.pl` present. The build also shipped a systemd
unit, an AD sample config, and a test client. The shipped unit got used; the
test client didn't work in an unprivileged container (killed on start, most
likely seccomp), so the Python `tacacs_plus` client replaced it.

## 3 — Local-only config, then 3b — validate with no device

Local test users first, AD later, so a directory problem could never be
confused with a ruleset problem.

**Check (3):** `tac_plus-ng -P` parses; `ss -tlnp` shows `:49`; two processes,
`spawnd` and a worker. That's why the config has two `id =` blocks.

**Check (3b):** `scripts/tac-validate.sh` against `127.0.0.1`. The read-only
user was permitted `show version` and **refused `configure terminal` at the
same privilege level**, and a user in no group was refused entirely. The whole
authorization design was proven before any network device took part.

Syntax lessons: quote every literal (an unquoted `!` ended the parse), and
`background = no`, `-f` and the implicit `Type=simple` all have to agree.

## 4 — One device, authentication only, rescue session open

3560CG-2 first, with a second session held open the whole time.

**Check:** admin login via TACACS+. This is also where the ERROR-versus-FAIL
behaviour first appeared: the local account stopped working over SSH the moment
the server was healthy. It led to the console method list, and later to
[findings.md §1](findings.md#1-local-catches-the-outage-is-cisco-behaviour-not-a-tacacs-rule).

The same change broke the backup tool, which logged in as that local account.
One event, visible from both systems:

```text
CA-OXI-LAB:  Net::SSH::AuthenticationFailed … @10.99.20.1
CA-TAC-LAB:  10.99.20.1  …  tty1  10.99.20.30  shell login failed
```

Because the backup tool's credential was global, **fixing one device would break
the other five**. So rolling AAA out to devices an automated system already logs
into is a credential migration, not just a device-config change. Per-node
credentials had to come first.

## 5 — Authorization and accounting on that device

**Check:**

```text
3560CG-2#configure terminal
Command authorization failed.
```

That was the read-only user, at privilege 15. Accounting start/stop records
appeared on the server.

## 6 — Fail-safe matrix

Originally one test: stop the server, confirm the local account works. That
only exercises ERROR, the failure mode where fallback already works. It was
rewritten to four scenarios. Results in
[verification.md](verification.md#fail-safe-matrix).

## 7, 8 — Active Directory through MAVIS, groups to profiles

**Check:** the admin user authenticated by the domain controller, landing at
privilege 15 via `memberOf`. The local test users still passed. Rules match the
full DN (`memberof =~ /^CN=NetAdmins,/`) *and* local membership, so both identity
sources work side by side.

## 9 — The other five devices

One at a time, re-testing an already-converted device after each ruleset
change. That's how the IOS privilege drop in
[findings.md §2](findings.md#2-optional-attributes-were-unreliable-in-both-directions)
was caught before it reached a second device.

| Device | What was different |
| --- | --- |
| 3560CG-1 | Across the tunnel. The server saw its real address, so the device entry matched as written |
| Arista 710P | The backup tool's `eos` model didn't redact the key on the host line (override in `configs/`) |
| SRX345 | `junos-exec`, template users, and a custom class, because the stock `read-only` class can't view configuration |
| PA-440 | `PaloAlto` service, PAP rather than CHAP, admin role returned as a vendor attribute, and a second device address once the MGT port was cabled |
| C2940 | 2003 image. The parser was probed with `?` before anything was configured, since `aaa new-model` is live the instant it's typed |

## 10 — Scoped backup service account

Six per-node credentials in the backup tool's device list, all
`svc-oxidized`, all read-only. Then the global fallback credential was deleted
from its config.

**Check:** all six nodes `success` through the backup tool's API, **after** the
fallback was removed. So every node demonstrably uses its own credential.
Timings in [verification.md](verification.md#backup-account-all-six-devices).

## 11 — Accounting to syslog

rsyslog on the same host. `tac_plus-ng` accounting to both a file and syslog.
The SRX and PA-440 forward their own logs, because they enforce locally.

**Check:** one event, both destinations:

```text
file    2026-09-21 04:48:34 +0000  10.99.0.2  casey  ttyp0  10.10.1.10  stop  shell  exit <cr>
syslog  ACCT-STOP|10.99.0.2|casey|ttyp0|10.10.1.10|stop|shell|exit <cr>
```

That's the SRX, whose accounting had never worked before this phase
([findings.md §4](findings.md#4-five-things-were-configured-correctly-and-didnt-work)).

## 12 — Before publishing anything

- `rewrite sanitize` on every log with a command in it, proven with a fake
  credential: `username redacttest secret 0 *** <cr>`
- Break-glass passwords rotated into an offline vault. 3560CG-2 confirmed at
  type 9 (scrypt), up from type 5 (MD5)
- Full-history scan of every public repository for device serials: none found
- Every log excerpt in this repository read by hand. The PA-440 puts its serial
  in field 3 of every syslog line
