# Verification

The output behind each claim. Addresses are the lab's real RFC 1918 addressing.
Keys, passwords, hashes and serial numbers are removed.

---

## Ruleset, with no device involved

```text
tac_plus-ng ruleset validation  2026-09-22T03:55:12Z
  OK    testadmin authenticates                  PASS
  OK    testadmin shell start                    PASS
  OK    testadmin may configure                  PASS
  OK    testro authenticates                     PASS
  OK    testro shell start                       PASS
  OK    testro may show                          PASS
  OK    testro REFUSED configure                 FAIL
  OK    testro REFUSED reload                    FAIL
  OK    no-group user REFUSED shell              FAIL
  OK    unknown user REFUSED                     FAIL
  OK    testadmin authenticates (PAP)            PASS
  OK    testro authenticates (PAP)               PASS
  OK    unknown user REFUSED (PAP)               FAIL

  13 passed, 0 failed
```

`FAIL` in the right-hand column is the expected answer for a refusal. `OK` means
the server gave the answer the check wanted.

## One account, one profile, four vendors

The backup account's authorization records across one backup cycle:

```text
10.99.20.1   svc-oxidized  tty1  10.99.20.30  readonly  permit  shell
10.99.20.1   svc-oxidized  tty1  10.99.20.30  readonly  permit  shell show running-config <cr>
10.99.10.14  svc-oxidized  vty3  10.99.20.30  readonly  permit  shell
10.99.10.14  svc-oxidized  vty3  10.99.20.30  readonly  deny    shell enable <cr>
10.99.10.14  svc-oxidized  vty3  10.99.20.30  readonly  permit  shell terminal length 0 <cr>
10.99.10.14  svc-oxidized  vty3  10.99.20.30  readonly  permit  shell show running-config <cr>
10.99.0.2    svc-oxidized        10.99.20.30  readonly  permit  junos-exec
10.99.20.2   svc-oxidized        10.99.20.30  readonly  permit  PaloAlto  protocol=firewall
```

## Read-only, enforced four ways

**IOS — the server refuses, per command:**

```text
C2940-LAB#configure terminal
Command authorization failed.

C2940-LAB#wr mem
Command authorization failed.
```

The admin user on the same switch, same session type, gets `[OK]` from `wr mem`.

**Junos — the local login class decides:** `configure` works for the admin
template user; for the read-only one it returns `unknown command`.

**PAN-OS — the role removes commands from the parser:**

```text
testro@PA440-LAB> show system info          → full output
testro@PA440-LAB> request restart system    → Invalid syntax.
testro@PA440-LAB> configure
testro@PA440-LAB# set deviceconfig system … → Unknown command: set
testro@PA440-LAB# delete deviceconfig …     → Unknown command: delete
```

`superreader` can enter `configure` to read the candidate config, but `set`,
`delete` and `request` aren't in its command tree. A blocked command reads as a
syntax error, not a permission error.

The firewall's own view of a TACACS+ login, from its forwarded syslog:

```text
SYSTEM,auth,…,auth-success,TACACS-AUTH,…,"authenticated for user 'svc-oxidized'.
  auth profile 'TACACS-AUTH', vsys 'shared', server profile 'TAC-LAB',
  server address '10.99.20.32', auth protocol 'PAP', admin role 'netops',
  From: 10.99.20.30."
```

That's the whole decision chain, recorded by the device. The server's matching
record is the `readonly permit PaloAlto` line above.

## Fail-safe matrix

On 3560CG-2, with an admin session held open throughout, plus a console test on
all six devices.

| # | Scenario | Result |
| --- | --- | --- |
| A | Server **stopped** (ERROR): local account over SSH | ✅ admitted, via `local` |
| A2 | Server stopped with a TACACS+ session **already open** | ✅ session kept working, via `if-authenticated` |
| B | Server **up and rejecting** (FAIL): local account over SSH | ✅ refused, as designed. IOS said `Password incorrect.`, though the password was correct |
| C | **Console cable**, server up and rejecting | ✅ **all six devices**, and privilege 15 reachable on all six |

The prompt shows which method answered, before the password is typed:

| Login | Prompt | Answered by |
| --- | --- | --- |
| IOS, server stopped | `(user@host) Password:` | local |
| IOS, server running | `User Access Verification` → `Password:` | TACACS+ |
| Junos, server stopped | `Local password:` | local |

## ERROR versus FAIL across vendors

Same local account, same server, server up and rejecting:

| Device | Result |
| --- | --- |
| IOS 15.x | refused |
| EOS | refused (`Error in authentication`) |
| Junos, `authentication-order [ tacplus password ]` | **admitted** |
| Junos, `authentication-order tacplus` | refused, and still admitted with the server stopped |
| PAN-OS | admitted in every state (the account is local by design) |

## Backup account, all six devices

Oxidized's REST API, after the global fallback credential was removed:

```text
3560CG-1           success       7.5s
3560CG-2           success       8.2s
C2940-LAB          success       6.1s
ARISTA710P-LAB     success       3.1s
SRX345-LAB         success      13.4s
PA440-LAB          success      50.1s
```

The PA-440 takes six times the median, because `show config running` includes
the App-ID catalogue. It measured 39 seconds on one run and 50 on the next,
against what was a 30-second timeout.

Duration is the better thing to alert on. A job creeping towards its timeout
shows up weeks before the first failure. Pass/fail shows nothing until the day
it breaks.

## Log sanitizing

A fake credential typed on 3560CG-2 to test the `rewrite`:

```text
stop  shell  username redacttest secret 0 *** <cr>
stop  shell  no username redacttest <cr>
```

The plaintext never reached disk.

Junos redacts its own secrets before sending them, so the server never sees
them:

```text
ACCT-STOP|10.99.0.2|…|set system accounting destination tacplus server 10.99.20.32 secret /* SECRET-DATA */ <cr>
```
