#!/bin/bash
# tac-validate.sh — validate the tac_plus-ng ruleset against the running server,
# with no network device involved.
#
# Runs on the TACACS+ server itself, through the "localhost" device entry, using
# tacacs_client from the tacacs_plus Python package:
#   python3 -m venv /opt/tactest && /opt/tactest/bin/pip install tacacs_plus
#
# The key and the test passwords are read out of the live config at runtime, so
# nothing secret is stored here, typed, or echoed.
#
# Exit code is the verdict (0 = all pass), so cron or a monitoring check can call it.
#
# History worth knowing: this reported 10/10 while PAP authentication was broken
# for every local user, because it only tested ASCII login. Then adding PAP
# passwords broke getpw() — two "clear" values per user — and it dropped to 8/10
# with nobody noticing, because nobody reran it. Run it after every change.

CFG=/etc/tac_plus-ng/tac_plus-ng.cfg
T=/opt/tactest/bin/tacacs_client
H=127.0.0.1
export TACACS_PLUS_KEY=$(sed -n 's/.*device localhost.*key = "\([^"]*\)".*/\1/p' "$CFG")
getpw() { awk "/user $1 \{/,/\}/" "$CFG" | sed -n 's/.*password login = clear "\([^"]*\)".*/\1/p'; }

pass=0; fail=0
check() {
  local desc="$1" want="$2" user="$3"; shift 3
  TACACS_PLUS_PWD=$(getpw "$user"); [ -z "$TACACS_PLUS_PWD" ] && TACACS_PLUS_PWD=nosuchpassword
  export TACACS_PLUS_PWD
  got=$("$T" -u "$user" -H "$H" -v "$@" 2>&1 | sed -n 's/^status: //p' | head -1)
  if [ "$got" = "$want" ]; then printf '  OK    %-40s %s\n' "$desc" "$got"; pass=$((pass+1))
  else printf '  FAIL  %-40s want %s got %s\n' "$desc" "$want" "$got"; fail=$((fail+1)); fi
}

echo "tac_plus-ng ruleset validation  $(date -u +%FT%TZ)"
check "testadmin authenticates"       PASS testadmin   authenticate
check "testadmin shell start"         PASS testadmin   authorize -c "service=shell" "cmd="
check "testadmin may configure"       PASS testadmin   authorize -c "service=shell" "cmd=configure" "cmd-arg=terminal"
check "testro authenticates"          PASS testro      authenticate
check "testro shell start"            PASS testro      authorize -c "service=shell" "cmd="
check "testro may show"               PASS testro      authorize -c "service=shell" "cmd=show" "cmd-arg=version"
check "testro REFUSED configure"      FAIL testro      authorize -c "service=shell" "cmd=configure" "cmd-arg=terminal"
check "testro REFUSED reload"         FAIL testro      authorize -c "service=shell" "cmd=reload"
check "no-group user REFUSED shell"   FAIL testnogroup authorize -c "service=shell" "cmd="
check "unknown user REFUSED"          FAIL nosuchuser  authenticate
check "testadmin authenticates (PAP)" PASS testadmin   -t pap authenticate
check "testro authenticates (PAP)"    PASS testro      -t pap authenticate
check "unknown user REFUSED (PAP)"    FAIL nosuchuser  -t pap authenticate
echo; echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
