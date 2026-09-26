# Findings

Each of these was discovered because something broke, not because a planned
check passed. They're ordered roughly by how much they changed the design.

---

## 1. "`local` catches the outage" is Cisco behaviour, not a TACACS+ rule

The method list `aaa authentication login default group TAC-GROUP local`
reads like "try TACACS+, fall back to local". On IOS it means something
narrower:

| Server state | Server says | IOS does |
| --- | --- | --- |
| Unreachable, timeout | nothing — **ERROR** | tries `local` |
| Up, rejects the user | "no" — **FAIL** | **stops.** `local` is never consulted |

So once IOS was converted, the local break-glass account — which TACACS+ has
never heard of — **could not log in over SSH while the server was healthy**. It
took a console-specific method list to keep a local path open.

That was treated as a property of TACACS+ for five devices. Tested deliberately
across all four vendors, same local user, same server, server up and rejecting:

| Device | Result | Prompt seen |
| --- | --- | --- |
| 3560CG-2 (IOS 15.x) | refused | `User Access Verification` |
| Arista 710P (EOS) | refused — `Error in authentication` | `User Access Verification` |
| SRX345 (Junos) | **admitted** | `User Access Verification` |
| PA-440 (PAN-OS) | **admitted** | `Password:` — no banner at all |

Two of four vendors did something else, for two different reasons.

**Junos** had `authentication-order [ tacplus password ]`. With `password` in
the list, Junos tries the local database after the server *rejects* a user. The
fix is to delete a word:

```text
delete system authentication-order password
```

That doesn't cause lockout, which is the counterintuitive part: with only remote
methods listed and no server responding, Junos falls back to the local database
anyway. Verified both ways:

| Server state | Prompt | Local account |
| --- | --- | --- |
| Up, rejecting | `User Access Verification` | refused |
| Stopped | **`Local password:`** | admitted |

Junos changes the prompt to `Local password:` when it falls back, so you can
tell which database is answering before you type anything.

**PAN-OS** doesn't have method lists. Authentication belongs to the *account*:
an admin defined locally authenticates locally, and the TACACS+ profile applies
to accounts that aren't. There's no ordering to fix. The local break-glass
account on the PA-440 is reachable over SSH in every server state, by design.

*A rule learned on one platform and generalised to the protocol is the
expensive kind of wrong. It reads like understanding right up until the vendor
that doesn't follow it is the firewall between the two sites.*

---

## 2. Optional attributes were unreliable in both directions

Each vendor asks for a different service, and wants a different attribute back:

| Vendor | Service | Attribute |
| --- | --- | --- |
| IOS, EOS | `shell` | `priv-lvl` |
| Junos | `junos-exec` | `local-user-name` |
| PAN-OS | `PaloAlto` + `protocol=firewall` | `PaloAlto-Admin-Role` |

In `tac_plus-ng`, `set` sends an attribute as mandatory and `add` as optional.
RFC 8907 lets a device ignore optional attributes it doesn't understand, so the
first attempt added Junos's `local-user-name` to the shared profiles as
optional, on the theory that the Ciscos would ignore it.

IOS did ignore it — along with everything else. The server logged
`full permit shell`, IOS threw away the entire reply, `priv-lvl 15` with it, and
the session landed at `>` instead of `#`. **"May ignore" turned out to mean
"will ignore all of them."**

On the PA-440 it went the other way. The admin role, sent with `add`, was
permitted by the server and ignored by the firewall: *"Invalid user. Please
login using a valid account."* Changing `add` to `set` fixed it immediately.

The resolution for both is the same: **scope each attribute to the service
that asked for it**, so no device ever receives another vendor's attribute.
Once scoped, `set` is safe.

```text
if (service == "junos-exec") { add local-user-name = netadmin  permit }
if (service == "PaloAlto") { set PaloAlto-Admin-Role = superuser  permit }
```

This was caught because the plan said to re-test an already-converted Cisco
before touching the next vendor.

---

## 3. CHAP can't work against an LDAP-bind backend, and PAP is two settings

PAN-OS was the first device that doesn't use TACACS+ ASCII login. Configured for
CHAP, it failed with `chap login failed (no such user)`.

That's structural, not a typo. With CHAP the server has to compute the
challenge response **from the cleartext password**. MAVIS authenticates by
binding to LDAP *as the user*, so this server never has anyone's password. Any
bind-style backend is incompatible with CHAP.

PAP sends the password (inside the TACACS+ body obfuscation) and lets the server
pass it through. It needed two more changes, neither implied by the working
ASCII setup:

```text
login backend = mavis
pap backend   = mavis      # separate setting
```

and, for local users:

```text
user testro {
    password login = clear "..."    # ASCII login
    password pap   = clear "..."    # PAP — a separate credential
}
```

AD users were unaffected throughout, because an LDAP bind doesn't care which
authentication type asked. **The test harness reported 10/10 the entire time**,
because it only ever tested ASCII. See finding 7.

---

## 4. Five things were configured correctly and didn't work

Each of these had correct-looking configuration. None of them produced the
right output. All five were found by checking what arrived, not what was
configured.

**The SRX backup succeeded with almost nothing in it.** Through the stock
Junos `read-only` class, the backup was 33 lines of hierarchy headers with
nothing underneath. That class has `view` but not `view-configuration`. Oxidized
reported success, committed it and pushed it. A custom class with
`view-configuration` brought it to 654 lines. This one is worse than a loud
failure: it would have been discovered during a restore.

**The PA-440 backup had been failing.** Oxidized logged retries and gave up.
The git log still looked fine, just stale. The `panos` model runs
`show config running`, which includes PAN-OS's entire predefined App-ID
catalogue, about 70,000 lines. The job takes 39–50 seconds against a global
`timeout:` of 30, so it was failing by nine seconds or more. Six earlier commits
show it had worked at some point. What pushed a borderline job over the line
isn't established. It wasn't a content update, since this PA-440 has no
support licence and can't download them. The login path had changed, though:
the account is now authenticated by TACACS+ over PAP, with an LDAP bind behind
it. Two retry attempts 40 seconds apart had been read as two successful backups.

**The PA-440's backups carried its chassis serial.** The upstream model strips
eight version fields from `show system info` and leaves `serial:`. Fixed with a
model override (see `configs/oxidized-model-overrides/`).

**SRX accounting had never produced a single record.** A per-device count of the
accounting log:

```text
    239  10.99.10.14   Arista
    154  10.99.20.1    3560CG-2
    113  10.99.10.1    3560CG-1
     63  10.99.20.20   C2940
      —  10.99.0.2     SRX345      ← zero, ever
```

The clue was in the daemon log:
`connection request from 10.255.255.2 … rejected (host unknown)`.
`10.255.255.2` is the SRX's IPsec tunnel endpoint, identified instantly by SSH,
which fingerprints hosts rather than addresses
(`This host key is known by the following other names/addresses: 10.99.0.2`).

Junos configures the TACACS+ server twice, for authentication and for
accounting, each with its own secret and its own source address, and says
nothing when they disagree. `system tacplus-server` had
`source-address 10.99.0.2`; `system accounting destination tacplus` didn't, so
accounting left via the tunnel and was refused. Authentication worked perfectly
the whole time.

**The old shared password was still in the backup tool's config.** After every
device had moved to per-node credentials, the global `username`/`password`
fallback was still sitting in plaintext near the top of the Oxidized config.
It was dead config, but it was also the exact credential this project set out to
eliminate.

---

## 5. On IOS, the read-only account can read the shared secret

Running as the read-only test user on the C2940:

```text
C2940-LAB#show running-config | include tacacs
tacacs-server host 10.99.20.32 key <plaintext key visible>
```

Two things combine. The read-only profile **must** permit
`show running-config`, because that's how the backup account works. And that
switch stored its key unencrypted.

This is a limit of the design IOS forces. Read-only has to land at privilege 15,
because `show running-config` needs 15, and per-command authorization does the
restricting. But no privilege model that allows that command can protect what's
in its output.

What actually helps:

| Mitigation | Effect |
| --- | --- |
| `service password-encryption` | Key becomes type 7. That's reversible, so it isn't protection, but it's the form redaction regexes expect |
| Backup-tool redaction | Keeps it out of the repository. A denylist, so it fails open |
| **Per-device keys** | A leaked key compromises one device's trust relationship, not six. This is the control that matters |

Junos handles this properly. The backup account's login class lacks the
`secret` permission bit, so it sees `## SECRET-DATA` instead of the encrypted
values. That's a permission bit, which fails closed, rather than a regex, which
fails open.

---

## 6. Console break-glass: exempt from authorization isn't the same as privileged

IOS 12.1's `aaa authorization ?` has no `console` option. The console is exempt
from authorization, unconditionally. That looked like a safer break-glass than
the 15.x switches, where console authorization had to be engineered.

Over a physical cable it turned out to be half true:

| Device | Console lands at |
| --- | --- |
| 3560CG-1, 3560CG-2 | `#`, privilege 15 |
| C2940, Arista | **`>`, privilege 1** |

IOS reads `username … privilege 15` off the local database **during
authorization**, not authentication. Exempt from authorization also means
exempt from privilege assignment. The 3560s land at `#` because they carry
`aaa authorization exec CONSOLE local if-authenticated`.

`enable` worked on both privilege-1 devices with the server up and rejecting, so
privilege 15 is reachable on the console of all six. But reaching the prompt
isn't break-glass. Reaching `#` is, and that needed checking separately.

---

## 7. The test harness validated one mode, twice, and then rotted

`scripts/tac-validate.sh` tests the ruleset against the running server with no
device involved. It caught real problems in the ruleset before any device was
touched. It also:

- **Reported 10/10 while PAP was broken** for every local user, including the
  break-glass test accounts. It only tested ASCII login.
- Sat alongside a fail-safe test that stopped the server, which exercises
  ERROR, and so could never have caught the FAIL behaviour in finding 1.
- **Broke when PAP was fixed.** Adding `password pap` gave each user two
  `clear "…"` values, the password-extraction function returned both on two
  lines, and authentication checks started failing. It dropped to 8/10 and
  nobody knew, because nobody reran it. Found by reading the source.

It now runs 13 checks across ASCII and PAP, and its exit code is the verdict.

*A test suite is code, and it rots like code. A harness that isn't rerun after
every change only tells you how things were the last time it ran.*

---

## 8. Surviving an outage mid-session

With per-command authorization, every command in an open session needs the
server. Stopping the server mid-session:

| Platform | Open TACACS+ session during outage |
| --- | --- |
| IOS, with `if-authenticated` | keeps working |
| IOS, without it | stays logged in, every command refused |
| EOS | no `if-authenticated` exists (`group`, `local`, `none` only). Expected to go inert |
| Junos, PAN-OS | authorization is a single grant at login and enforcement is local, so commands shouldn't need the server. Inferred, not tested |

`none` isn't a substitute on EOS. It means "always succeeds", in every state.
So the Arista's behaviour is documented rather than papered over.

The two platforms that give the weakest central audit trail (finding 10) give
the best outage behaviour. Local enforcement means local survival.

---

## 9. Devices and tools misreport why authentication failed

- IOS, with the correct password for a local account the server rejected:
  **`Password incorrect.`** The password was right. IOS can't express "the
  server said no".
- `tacacs_client` returns identical output for a wrong password and for a valid
  user refused by the ruleset. That cost an hour on two accounts that had
  authenticated correctly and been refused by `r-deny`, exactly as designed.

Both ends report a credential problem when the cause is an authorization
decision. The server's `access.log` tells them apart (`login failed` versus
`denied by ACL`). **Check it before retyping a password.**

---

## 10. Where the per-command audit trail actually comes from

| Platform | Every command recorded centrally? | Via |
| --- | --- | --- |
| IOS ×3, EOS | ✅ | TACACS+ per-command authorization and accounting |
| Junos | ✅ | TACACS+ accounting (`interactive-commands`); authorization is one session grant |
| PAN-OS | ❌ config changes and logins only | syslog. There is no operational-command log |

Junos also **redacts its own secrets** before sending them. Captured while
fixing finding 4:

```text
ACCT-STOP|…|set system accounting destination tacplus server 10.99.20.32 secret /* SECRET-DATA */ <cr>
```

IOS doesn't. That's why the server applies a `rewrite` to every log, and why its
pattern uses `\S+` rather than the manual's `\w+`: `\w+` can't match a value
starting with `$`, and every Cisco hash starts with `$`.

Two server-side traps from the same work:

- **A second `destination =` in one log block replaces the first.** Adding
  syslog as a second destination silently stopped file accounting for every
  device. The parse was clean. The fix is a second named log, assigned twice.
- **Reload isn't restart.** A fix to an existing user object failed every test
  for twenty minutes after a `systemctl reload`, and worked on the first attempt
  after a `restart`. The likely reason is that `spawnd` workers each hold their
  own copy of the config. Either way: for changes to existing users, restart.

## 11. A `$` anchor in a command pattern is defeated by IOS's `<cr>`

IOS appends `<cr>` as the final argument of every command authorization
request. `tac_plus-ng` includes it in the string a `cmd =~` pattern is matched
against. So this pattern, which looks obviously correct:

```text
if (cmd =~ /^(no )?ip http (secure-)?server$/) permit
```

never matches a real device, because the string arriving is
`no ip http server <cr>`. The command is refused.

**It fails closed.** A broken allowlist entry denies something legitimate
rather than permitting something dangerous, which is the right direction — and
also the reason nobody notices. There is no error, no warning, and the config
parses.

Found by a test written to *expect* the problem, before any device used the
profile:

```text
OK    testdeploy may disable http              PASS
FAIL  ...disable http, with <cr>               want PASS got FAIL
```

Twenty-seven other checks passed. Without the pair, the allowlist would have
looked proven.

**The fix** is to make the terminator optional rather than to drop the anchor —
dropping it would turn `^configure( terminal)?$` into a pattern that also
permits `configure replace`:

```text
if (cmd =~ /^(no )?ip http (secure-)?server( ?<cr>)?$/) permit
```

The same defect was already present in this repository's `readonly` profile, in
`if (cmd =~ /^exit$/)`. The authorization log showed **no `exit` requests at
all** — the backup tool closes the TCP session instead of typing `exit`, and
human sessions are closed client-side — so it had never been exercised. In a
deny-by-default ruleset a broken pattern stays invisible until something
depends on it.

Two general points, both of which this lab has now hit twice:

- **Anchored patterns need to know exactly what the device sends**, including
  terminators. Read a real authorization request before trusting a `$`.
- **Prefix patterns (`/^show/`) are immune and commonly used for that reason**,
  but they are also looser. If a pattern needs to be exact, test it against the
  device's actual argument list rather than against what the command looks like
  when typed.
