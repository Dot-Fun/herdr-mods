#!/bin/zsh
set -euo pipefail
unsetopt BG_NICE

script=${0:A:h}/mods/agent-revive/hc-revive
test_root=$(mktemp -d "${TMPDIR:-/tmp}/hc-revive-test.XXXXXX")
trap 'if [[ ${KEEP_HC_REVIVE_TEST_TMP:-0} == 1 ]]; then print -u2 -- "kept $test_root"; else rm -rf -- "$test_root"; fi' EXIT

core_a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
core_b=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
core_c=cccccccccccccccccccccccccccccccc
session_1=11111111-1111-1111-1111-111111111111
session_2=22222222-2222-2222-2222-222222222222
boot_a1=aaaaaaaa-1111-1111-1111-111111111111
boot_a2=aaaaaaaa-2222-2222-2222-222222222222
boot_b1=bbbbbbbb-1111-1111-1111-111111111111
local_boot=local-test-boot
tests=0

fail() { print -u2 -- "not ok: $*"; exit 1; }
pass() { (( tests += 1 )); print -- "ok $tests - $*"; }
assert_jq() {
  local file=$1 expression=$2 message=$3
  jq -e "$expression" "$file" >/dev/null || { jq . "$file" >&2; fail "$message"; }
}
assert_eq() { [[ $1 == "$2" ]] || fail "$3 (got '$1', want '$2')"; }

mkdir -p "$test_root/mocks"
cat > "$test_root/mocks/hc" <<'MOCK'
#!/bin/zsh
set -u
print -r -- "$*" >> "$HC_CALLS"

fixture() {
  local file=$1
  [[ -f "$HC_FIXTURES/$file" ]] || return 1
  /bin/cat "$HC_FIXTURES/$file"
}

if [[ ${1:-} == server && ${2:-} == status ]]; then
  print -r -- "{\"id\":\"${HC_SELF_ID}\"}"
  exit 0
fi
if [[ ${1:-} == machine && ${2:-} == ls && ${3:-} == --json ]]; then
  fixture machines.json
  exit $?
fi
if [[ ${1:-} == ls && ${2:-} == --json ]]; then
  fixture ls.json
  exit $?
fi
if [[ ${1:-} == get && ${3:-} == --json ]]; then
  target=$2
  if [[ -n ${HC_REMOTE_ALIAS:-} && $target == t<-> ]]; then
    name="${HC_REMOTE_ALIAS}__${target}"
    body=$(fixture "get.$name.json") || exit 1
    jq -c --arg target "$target" 'if type == "object" and has("address") then .address = $target else . end' <<< "$body"
  else
    name=${target//\//__}
    fixture "get.$name.json"
  fi
  exit $?
fi
if [[ ${1:-} == send ]]; then
  target=$2
  display=$target
  if [[ -n ${HC_REMOTE_ALIAS:-} && $target == t<-> ]]; then
    display="${HC_REMOTE_ALIAS}/$target"
  fi
  key=${display//\//__}
  print -r -- "$display"$'\t'"$3" >> "$HC_SEND_ATTEMPTS"
  print -r -- "send $display" >> "$HC_EVENT_LOG"
  if [[ -f "$HC_FIXTURES/hang.$key" ]]; then
    # This helper and its child wait until fixture teardown, even across TERM.
    trap '' TERM
    (while [[ -f "$HC_FIXTURES/hang.$key" ]]; do /bin/sleep 0.2; done) &
    child=$!
    print -r -- "$$ $child" > "$HC_FIXTURES/hung.$key"
    wait "$child"
    exit 1
  fi
  if [[ -f "$HC_FIXTURES/hold.$key" ]]; then
    : > "$HC_FIXTURES/holding.$key"
    for _ in {1..1000}; do
      [[ -f "$HC_FIXTURES/release.$key" ]] && break
      /bin/sleep 0.01
    done
    [[ -f "$HC_FIXTURES/release.$key" ]] || exit 1
  fi
  if [[ -f "$HC_FIXTURES/status.send.$key" ]]; then
    exit "$(<"$HC_FIXTURES/status.send.$key")"
  fi
  print -r -- "$display"$'\t'"$3" >> "$HC_SENDS"
  exit 0
fi
if [[ ${1:-} == exec ]]; then
  shift
  interactive=false
  alias=''
  while (( $# )); do
    case $1 in
    -i) interactive=true; shift ;;
    --on) alias=$2; shift 2 ;;
    --timeout) shift 2 ;;
    --) shift; break ;;
    *) break ;;
    esac
  done
  [[ -n $alias ]] || exit 99
  [[ $interactive == true ]] || exit 99
  [[ ${1:-} == zsh && ${2:-} == -s && ${3:-} == -- ]] || exit 99
  mode=${4:-}
  expected=${5:-}
  actual=$expected
  [[ -f "$HC_FIXTURES/id.$alias" ]] && actual=$(<"$HC_FIXTURES/id.$alias")
  print -r -- "exec $alias $mode" >> "$HC_EVENT_LOG"
  exit_code=0
  case $mode in
  remote-scan)
    while IFS= read -r _line; do :; done
    [[ $actual == "$expected" ]] || exit 90
    [[ -f "$HC_FIXTURES/status.scan.$alias" ]] && exit_code=$(<"$HC_FIXTURES/status.scan.$alias")
    body=$(fixture "scan.$alias") || exit 1
    jq -c --arg core_id "$actual" '. + {core_id: $core_id}' <<< "$body"
    exit "$exit_code"
    ;;
  remote-boot)
    while IFS= read -r _line; do :; done
    [[ $actual == "$expected" ]] || exit 90
    [[ -f "$HC_FIXTURES/status.boot.$alias" ]] && exit_code=$(<"$HC_FIXTURES/status.boot.$alias")
    value=$(fixture "boot.$alias") || exit 1
    jq -cn --arg core_id "$actual" --arg boot "$value" '{core_id: $core_id, boot: $boot}'
    exit "$exit_code"
    ;;
  remote-restore)
    output=$(HC_REMOTE_ALIAS="$alias" HC_SELF_ID="$actual" zsh -s -- "$mode" "${@:5}")
    child_status=$?
    [[ -n $output ]] && print -r -- "$output"
    [[ -f "$HC_FIXTURES/status.restore.$alias" ]] && exit "$(<"$HC_FIXTURES/status.restore.$alias")"
    exit "$child_status"
    ;;
  *) exit 99 ;;
  esac
fi
exit 99
MOCK

cat > "$test_root/mocks/ps" <<'MOCK'
#!/bin/zsh
/bin/cat "$HC_FIXTURES/ps.txt"
MOCK

cat > "$test_root/mocks/lsof" <<'MOCK'
#!/bin/zsh
[[ -f "$HC_FIXTURES/status.lsof" ]] && exit "$(<"$HC_FIXTURES/status.lsof")"
/bin/cat "$HC_FIXTURES/lsof.txt"
MOCK

cat > "$test_root/mocks/sleep" <<'MOCK'
#!/bin/zsh
exit 0
MOCK

# Inject failures before the real zsh rename, which still runs in the lock owner.
export ZDOTDIR=$test_root
cat > "$ZDOTDIR/.zshenv" <<'MOCK'
zf_mv() { "$HOME/.local/bin/before-publish" "$@" && builtin zf_mv "$@"; }
# Pause this finalizer after it reads the old record, just before taking the lock.
if [[ ${1:-} == finish-worker && -f $HC_FIXTURES/pause-finish.${2:-} ]]; then
  chmod() {
    print -r -- "$$" > "$HC_FIXTURES/finalizer-waiting"
    for _ in {1..1000}; do
      [[ -e $HC_FIXTURES/release-finalizer ]] && break
      /bin/sleep 0.02
    done
    command chmod "$@"
  }
fi
MOCK

cat > "$test_root/mocks/before-publish" <<'MOCK'
#!/bin/zsh
set -u
print -r -- "$*" >> "$HC_MV_LOG"
dest=${argv[-1]}
print -r -- "mv ${dest:t}" >> "$HC_EVENT_LOG"
if [[ ${HC_FAIL_SNAPSHOT_MV:-0} == 1 && $dest == */snapshot.json && ! -f "$HC_FIXTURES/mv-failed" ]]; then
  : > "$HC_FIXTURES/mv-failed"
  exit 1
fi
if [[ $dest == */pending.json && -s "$HC_SENDS" && -f "$HC_FIXTURES/fail-checkpoint" ]]; then
  exit 1
fi
if [[ -f "$HC_FIXTURES/hold-rename" && ! -f "$HC_FIXTURES/holding-rename" ]]; then
  : > "$HC_FIXTURES/holding-rename"
  for _ in {1..1000}; do
    [[ -f "$HC_FIXTURES/release-rename" ]] && break
    /bin/sleep 0.01
  done
  : > "$HC_FIXTURES/rename-released"
fi
exit 0
MOCK

cat > "$test_root/mocks/sync" <<'MOCK'
#!/bin/zsh
count=0
[[ -f $HC_SYNC_COUNT ]] && count=$(<"$HC_SYNC_COUNT")
(( count += 1 ))
print -r -- "$count" > "$HC_SYNC_COUNT"
print -r -- "sync" >> "$HC_EVENT_LOG"
[[ ${HC_FAIL_SYNC:-0} == 1 ]] && exit 1
[[ ${HC_FAIL_SYNC_AT:-0} == $count ]] && exit 1
exit 0
MOCK

chmod +x "$test_root"/mocks/*

new_case() {
  local name=$1
  case_root=$test_root/$name
  export HOME=$case_root/home
  export HC_FIXTURES=$case_root/fixtures
  export HC_REVIVE_STATE=$case_root/state
  export HC_CALLS=$case_root/calls.log
  export HC_SENDS=$case_root/sends.log
  export HC_SEND_ATTEMPTS=$case_root/send-attempts.log
  export HC_MV_LOG=$case_root/mv.log
  export HC_EVENT_LOG=$case_root/events.log
  export HC_SYNC_COUNT=$case_root/sync-count
  export HC_REVIVE_BOOT=$local_boot
  export HC_SELF_ID=$core_a
  unset HC_FAIL_SNAPSHOT_MV || true
  unset HC_FAIL_SYNC || true
  unset HC_FAIL_SYNC_AT || true
  unset HC_REMOTE_ALIAS || true
  mkdir -p "$HOME/.local/bin" "$HOME/.claude/sessions" "$HC_FIXTURES"
  cp "$test_root"/mocks/* "$HOME/.local/bin/"
  : > "$HC_CALLS"
  : > "$HC_SENDS"
  : > "$HC_SEND_ATTEMPTS"
  : > "$HC_MV_LOG"
  : > "$HC_EVENT_LOG"
  print 0 > "$HC_SYNC_COUNT"
  : > "$HC_FIXTURES/ps.txt"
  : > "$HC_FIXTURES/lsof.txt"
  print '{"machines":[]}' > "$HC_FIXTURES/machines.json"
  print '{"terminals":[]}' > "$HC_FIXTURES/ls.json"
}

run_revive() { zsh "$script" "$@"; }
write_get() {
  local address=$1 body=$2
  print -r -- "$body" > "$HC_FIXTURES/get.${address//\//__}.json"
}
old_mtime() { touch -t 202001010000 "$1"; }
wait_worker() {
  local want=$1
  for _ in {1..500}; do
    if jq -e --arg want "$want" '.status == $want' "$HC_REVIVE_STATE/worker.json" >/dev/null 2>&1; then return 0; fi
    /bin/sleep 0.02
  done
  fail "worker never reported $want"
}
configure_local_agent() {
  print '{"terminals":[{"address":"t1"}]}' > "$HC_FIXTURES/ls.json"
  write_get t1 '{"address":"t1","state":"live","keep":true,"pid":100,"foreground":null}'
  print '100 ttys001 zsh\n200 ttys001 claude' > "$HC_FIXTURES/ps.txt"
  print -r -- "{\"cwd\":\"/work\",\"sessionId\":\"$session_1\"}" > "$HOME/.claude/sessions/200.json"
}

# The remote entrypoint reuses local discovery but does not create state on the target.
new_case remote_scan
print '{"terminals":[{"address":"t1"}]}' > "$HC_FIXTURES/ls.json"
write_get t1 '{"address":"t1","state":"live","keep":true,"pid":100,"foreground":null}'
print '100 ttys001 zsh\n200 ttys001 claude' > "$HC_FIXTURES/ps.txt"
print -r -- "{\"cwd\":\"/srv/remote\",\"sessionId\":\"$session_1\"}" > "$HOME/.claude/sessions/200.json"
remote=$(HC_REVIVE_BOOT=$boot_a1 run_revive remote-scan "$core_a")
jq -e --arg boot "$boot_a1" --arg session "$session_1" '
  .core_id == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  and .boot == $boot and (.terminals | length) == 1
  and .terminals[0] == {terminal:"t1",cwd:"/srv/remote",agent:"claude",session:$session}
' <<< "$remote" >/dev/null || fail 'remote discovery JSON'
[[ ! -e $HC_REVIVE_STATE ]] || fail 'remote-scan created controller state'
pass 'remote discovery is structured and state-free'

# A remote helper must reject a route that resolves to a different permanent core.
HC_SELF_ID=$core_b
if HC_REVIVE_BOOT=$boot_a1 run_revive remote-scan "$core_a" >/dev/null 2>&1; then
  fail 'remote discovery accepted the wrong permanent core'
fi
HC_SELF_ID=$core_a
pass 'remote discovery binds its response to the expected permanent core'

# Missing, partial, or malformed terminal JSON must fail discovery instead of looking empty.
new_case remote_input_validation
print '{"oops":[]}' > "$HC_FIXTURES/ls.json"
if HC_REVIVE_BOOT=$boot_a1 run_revive remote-scan "$core_a" >/dev/null 2>&1; then
  fail 'missing remote terminals array was accepted'
fi
print '{"terminals":[{"address":"t1"},{"missing":"address"}]}' > "$HC_FIXTURES/ls.json"
if HC_REVIVE_BOOT=$boot_a1 run_revive remote-scan "$core_a" >/dev/null 2>&1; then
  fail 'partial remote terminal listing was accepted'
fi
print '{"terminals":[{"address":"t1"}]}' > "$HC_FIXTURES/ls.json"
write_get t1 '{}'
if HC_REVIVE_BOOT=$boot_a1 run_revive remote-scan "$core_a" >/dev/null 2>&1; then
  fail 'malformed remote terminal details were accepted'
fi
write_get t1 '{"address":"t1","state":"live","keep":true,"pid":1.5,"foreground":null}'
if HC_REVIVE_BOOT=$boot_a1 run_revive remote-scan "$core_a" >/dev/null 2>&1; then
  fail 'fractional remote root pid was accepted'
fi
pass 'remote discovery fails closed on malformed hc output'

# Every top-level stateful command uses one persistent fcntl lock. Contention is
# fail-closed, old lock-file mtimes are irrelevant, and process exit releases it.
new_case mutation_lock
configure_local_agent
mkdir -p "$HC_REVIVE_STATE"
print -r -- "{\"version\":2,\"boot\":\"$local_boot\",\"machines\":{},\"terminals\":[
 {\"machine\":null,\"terminal\":\"t1\",\"cwd\":\"/work\",\"agent\":\"claude\",\"session\":\"$session_1\",\"seen\":0}]}" > "$HC_REVIVE_STATE/snapshot.json"
cp "$HC_REVIVE_STATE/snapshot.json" "$HC_FIXTURES/snapshot.before"
: > "$HC_REVIVE_STATE/mutation.lock"
old_mtime "$HC_REVIVE_STATE/mutation.lock"
lock_mtime=$(stat -f %m "$HC_REVIVE_STATE/mutation.lock")
lock_inode=$(stat -f %i "$HC_REVIVE_STATE/mutation.lock")
ready=$HC_FIXTURES/lock-ready
release=$HC_FIXTURES/lock-release
zsh -fc '
  zmodload zsh/system || exit 1
  zsystem flock -f lock_fd "$1" || exit 1
  print ready > "$2"
  for _ in {1..500}; do
    [[ -e "$3" ]] && exit 0
    /bin/sleep 0.01
  done
  exit 1
' lock-holder "$HC_REVIVE_STATE/mutation.lock" "$ready" "$release" &
lock_holder=$!
for _ in {1..200}; do
  [[ -e $ready ]] && break
  /bin/sleep 0.01
done
[[ -e $ready ]] || fail 'lock holder did not start'
if run_revive save >/dev/null; then fail 'contended save reported success'; fi
run_revive tick
if run_revive restore; then fail 'contended restore reported success'; fi
cmp -s "$HC_FIXTURES/snapshot.before" "$HC_REVIVE_STATE/snapshot.json" || fail 'contended command changed the snapshot'
[[ ! -s $HC_SENDS ]] || fail 'contended restore sent data'
[[ -f $HC_REVIVE_STATE/mutation.lock ]] || fail 'live lock file was removed'
assert_eq "$(stat -f %Lp "$HC_REVIVE_STATE/mutation.lock")" 600 'mutation lock permissions'
assert_eq "$(stat -f %m "$HC_REVIVE_STATE/mutation.lock")" "$lock_mtime" 'old lock mtime was rewritten or reaped'
print release > "$release"
wait "$lock_holder"
rm -f "$HC_REVIVE_STATE/snapshot.json"
run_revive tick
[[ -f $HC_REVIVE_STATE/snapshot.json ]] || fail 'tick internal save deadlocked or failed after lock release'
assert_eq "$(stat -f %i "$HC_REVIVE_STATE/mutation.lock")" "$lock_inode" 'persistent lock file was replaced'
zsh -fc 'zmodload zsh/system && zsystem flock -t 0 -f lock_fd "$1"' \
  lock-probe "$HC_REVIVE_STATE/mutation.lock" || fail 'process exit did not release mutation lock'
pass 'save, restore, and tick share an auto-released persistent mutation lock'

new_case killed_publisher
configure_local_agent
: > "$HC_FIXTURES/hold-rename"
zsh "$script" save >/dev/null &
publisher=$!
for _ in {1..1000}; do [[ -f "$HC_FIXTURES/holding-rename" ]] && break; /bin/sleep 0.01; done
[[ -f "$HC_FIXTURES/holding-rename" ]] || fail 'publisher did not reach rename'
kill -KILL "$publisher"
wait "$publisher" 2>/dev/null || true
jq -n --arg id "$session_2" '{cwd:"/new",sessionId:$id}' > "$HOME/.claude/sessions/200.json"
run_revive save >/dev/null
: > "$HC_FIXTURES/release-rename"
for _ in {1..1000}; do [[ -f "$HC_FIXTURES/rename-released" ]] && break; /bin/sleep 0.01; done
[[ -f "$HC_FIXTURES/rename-released" ]] || fail 'released old pre-publication hook never finished'
assert_jq "$HC_REVIVE_STATE/snapshot.json" '.terminals | length == 1 and .[0].cwd == "/new"' 'killed owner replaced newer state'
pass 'a killed publisher cannot rename over the next lock owner'

new_case abandoned_temp
configure_local_agent
mkdir -p "$HC_REVIVE_STATE"
print original > "$HC_FIXTURES/unrelated"
ln -s "$HC_FIXTURES/unrelated" "$HC_REVIVE_STATE/.snapshot.json.tmp"
run_revive save >/dev/null
assert_eq "$(<"$HC_FIXTURES/unrelated")" original 'save followed a stale staging symlink'
assert_eq "$(stat -f %Lp "$HC_REVIVE_STATE/snapshot.json")" 600 'replacement snapshot lost private mode'
pass 'abandoned staging names cannot redirect the new snapshot'

# V1 local entries migrate; remote aliases and unknown commands remain inert evidence.
new_case migration
print -r -- "{\"machines\":[
 {\"name\":\"old-a\",\"id\":\"$core_a\",\"state\":\"unreachable\",\"temporary\":false},
 {\"name\":\"new-a\",\"id\":\"$core_a\",\"state\":\"connected\",\"temporary\":false}]}" > "$HC_FIXTURES/machines.json"
print '{"terminals":[{"address":"t1"},{"address":"new-a/t4"}]}' > "$HC_FIXTURES/ls.json"
write_get t1 '{"address":"t1","state":"live","keep":true,"pid":100,"foreground":null}'
print '100 ttys001 zsh\n200 ttys001 claude' > "$HC_FIXTURES/ps.txt"
print -r -- "{\"cwd\":\"/work/new\",\"sessionId\":\"$session_1\"}" > "$HOME/.claude/sessions/200.json"
mkdir -p "$HC_REVIVE_STATE"
now=$(date +%s)
print -r -- "{\"boot\":\"$local_boot\",\"terminals\":[
 {\"address\":\"t9\",\"cwd\":\"/work/old\",\"cmd\":\"codex resume $session_2\",\"seen\":$now},
 {\"address\":\"old-a/t4\",\"cwd\":\"/srv/a\",\"cmd\":\"claude --resume $session_2\",\"seen\":0},
 {\"address\":\"t8\",\"cwd\":\"/tmp\",\"cmd\":\"codex resume $session_1; touch /tmp/evil\",\"seen\":$now}] }" > "$HC_REVIVE_STATE/snapshot.json"
run_revive save >/dev/null
assert_jq "$HC_REVIVE_STATE/snapshot.json" ".version == 2 and (.machines == {})" 'snapshot did not migrate to v2'
assert_jq "$HC_REVIVE_STATE/snapshot.json" ".terminals | any(.machine == null and .terminal == \"t1\" and .agent == \"claude\")" 'new local agent missing'
assert_jq "$HC_REVIVE_STATE/snapshot.json" ".terminals | any(.machine == null and .terminal == \"t9\" and .agent == \"codex\")" 'v1 local entry not migrated'
assert_jq "$HC_REVIVE_STATE/snapshot.json" '.terminals | any(.legacy == true and .address == "old-a/t4" and (.machine == null))' 'v1 remote alias did not remain inert'
assert_jq "$HC_REVIVE_STATE/snapshot.json" '.terminals | any(.legacy == true and .address == "t8" and (.agent == null))' 'malicious v1 command was not inert'
assert_eq "$(stat -f %Lp "$HC_REVIVE_STATE/snapshot.json")" 600 'snapshot permissions'
assert_eq "$(stat -f %Lp "$HC_REVIVE_STATE")" 700 'state directory permissions'
pass 'v1 migration preserves local behavior and keeps remote aliases inert'

# V1 pending files migrate safe local rows, but never bind legacy remote aliases to current cores.
new_case pending_migration
print -r -- "{\"machines\":[
 {\"name\":\"old-a\",\"id\":\"$core_a\",\"state\":\"unreachable\"},
 {\"name\":\"new-a\",\"id\":\"$core_a\",\"state\":\"connected\"}]}" > "$HC_FIXTURES/machines.json"
mkdir -p "$HC_REVIVE_STATE"
print -r -- "{\"version\":2,\"boot\":\"$local_boot\",\"machines\":{\"$core_a\":\"$boot_a1\"},\"terminals\":[]}" > "$HC_REVIVE_STATE/snapshot.json"
print -r -- "{\"boot\":\"$local_boot\",\"tries\":4,\"terminals\":[
 {\"address\":\"old-a/t4\",\"cwd\":\"/srv\",\"cmd\":\"claude --resume $session_2\",\"seen\":0},
 {\"address\":\"t4\",\"cwd\":\"/local\",\"cmd\":\"claude --resume $session_1\",\"seen\":0},
 {\"address\":\"t8\",\"cwd\":\"/tmp\",\"cmd\":\"codex resume $session_1; touch /tmp/evil\",\"seen\":0}]}" > "$HC_REVIVE_STATE/pending.json"
run_revive tick
assert_jq "$HC_REVIVE_STATE/pending.json" ".version == 2 and .tries == 4
  and (.terminals | any(.machine == null and .terminal == \"t4\"
    and .agent == \"claude\" and .session == \"$session_1\" and .tries == 4))
  and (.terminals | any(.legacy == true and .address == \"old-a/t4\" and .session == null))
  and (.terminals | any(.legacy == true and .address == \"t8\"))" 'v1 pending migration lost identity, retry, or inert evidence'
assert_eq "$(stat -f %Lp "$HC_REVIVE_STATE/pending.json")" 600 'migrated pending permissions'
[[ ! -s $HC_SENDS ]] || fail 'v1 pending migration sent data without a route'
pass 'v1 pending migrates local rows and keeps remote aliases inert'

# V1 local rows that migrate onto the same stable terminal are retained as explicit
# collision evidence, but neither row remains actionable.
new_case local_migration_collision
print '{"terminals":[{"address":"t1"}]}' > "$HC_FIXTURES/ls.json"
write_get t1 '{"address":"t1","state":"live","keep":true,"pid":100,"foreground":null}'
mkdir -p "$HC_REVIVE_STATE"
print -r -- "{\"version\":2,\"boot\":\"$local_boot\",\"machines\":{},\"terminals\":[]}" > "$HC_REVIVE_STATE/snapshot.json"
print -r -- "{\"boot\":\"$local_boot\",\"terminals\":[
 {\"address\":\"t1\",\"cwd\":\"/one\",\"cmd\":\"codex resume $session_1\"},
 {\"address\":\"t1\",\"cwd\":\"/two\",\"cmd\":\"claude --resume $session_2\"}]}" > "$HC_REVIVE_STATE/pending.json"
run_revive tick
assert_jq "$HC_REVIVE_STATE/pending.json" '.terminals | length == 2
  and all(.legacy == true and .collision == true)' 'migrated collision was not retained inert'
[[ ! -s $HC_SEND_ATTEMPTS ]] || fail 'migrated collision reached send'
pass 'migration marks colliding stable terminal identities inert'

# V2 pending collisions remain as inert evidence.
new_case v2_collision
print -r -- "{\"machines\":[{\"name\":\"new-a\",\"id\":\"$core_a\",\"state\":\"connected\"}]}" > "$HC_FIXTURES/machines.json"
print '{"terminals":[{"address":"new-a/t1"}]}' > "$HC_FIXTURES/ls.json"
write_get new-a/t1 '{"address":"new-a/t1","state":"live","keep":true,"pid":100,"foreground":null}'
mkdir -p "$HC_REVIVE_STATE"
print -r -- "{\"version\":2,\"boot\":\"$local_boot\",\"machines\":{\"$core_a\":\"$boot_a1\"},\"terminals\":[]}" > "$HC_REVIVE_STATE/snapshot.json"
print -r -- "{\"version\":2,\"baseline\":{\"machines\":{}},\"terminals\":[
 {\"machine\":\"$core_a\",\"terminal\":\"t1\",\"cwd\":\"/one\",\"agent\":\"codex\",\"session\":\"$session_1\"},
 {\"machine\":\"$core_a\",\"terminal\":\"t1\",\"cwd\":\"/two\",\"agent\":\"claude\",\"session\":\"$session_2\"}]}" > "$HC_REVIVE_STATE/pending.json"
cp "$HC_REVIVE_STATE/pending.json" "$HC_FIXTURES/pending.before"
run_revive tick
assert_jq "$HC_REVIVE_STATE/pending.json" '.terminals | length == 2 and all(.legacy and .collision)' 'v2 collision evidence was lost'
[[ ! -s $HC_SEND_ATTEMPTS ]] || fail 'v2 collision reached send'
pass 'v2 pending collisions retain both rows as inert evidence'

new_case snapshot_collision
configure_local_agent
mkdir -p "$HC_REVIVE_STATE"
jq -n --arg id "$session_1" --arg other "$session_2" '
 {version:2,boot:"prior",machines:{},terminals: [
  {machine:null,terminal:"t1",cwd:"/work",agent:"codex",session:$id},
  {machine:null,terminal:"t1",cwd:"/work",agent:"claude",session:$other},
  {machine:null,terminal:"t2",cwd:"/work",agent:"claude",session:$other}]}' > "$HC_REVIVE_STATE/snapshot.json"
write_get t2 '{"address":"t2","state":"live","keep":true,"pid":101,"foreground":null}'
run_revive tick
assert_jq "$HC_REVIVE_STATE/snapshot.json" '[.terminals[] | select(.collision and .legacy)] | length == 2' 'snapshot collision lost evidence'
assert_eq "$(cut -f1 "$HC_SEND_ATTEMPTS")" t2 'snapshot collision reached send or blocked independent work'
assert_jq "$HC_REVIVE_STATE/snapshot.json" '[.terminals[] | select(.terminal == "t1" and .legacy != true)] | length == 0' 'save reactivated an ambiguous terminal'
pass 'snapshot collisions survive reboot selection while an independent entry resumes'

new_case process_collision
configure_local_agent
print '300 ttys001 claude' >> "$HC_FIXTURES/ps.txt"
jq -n --arg id "$session_2" '{cwd:"/second",sessionId:$id}' > "$HOME/.claude/sessions/300.json"
run_revive save >/dev/null
assert_jq "$HC_REVIVE_STATE/snapshot.json" '.terminals | length == 2 and all(.legacy and .collision)' 'discovery chose one of two sessions on one tty'
pass 'discovery retains different sessions observed on the same local terminal'

new_case remote_process_collision
mkdir -p "$HC_REVIVE_STATE"
jq -n --arg core "$core_a" '{machines:[{name:"box",id:$core,state:"connected"}]}' > "$HC_FIXTURES/machines.json"
print '{"terminals":[{"address":"box/t1"}]}' > "$HC_FIXTURES/ls.json"
jq -n --arg boot "$boot_a1" --arg id "$session_1" --arg other "$session_2" '
 {boot:$boot,terminals:[$id,$other | {terminal:"t1",cwd:"/work",agent:"claude",session:.}]}' > "$HC_FIXTURES/scan.box"
jq -n --arg boot "$local_boot" --arg core "$core_a" --arg prior "$boot_a1" --arg id "$session_1" '
 {version:2,boot:$boot,machines:{($core):$prior},terminals:[
 {machine:$core,terminal:"t2",cwd:"/saved",agent:"codex",session:$id,seen:0}]}' > "$HC_REVIVE_STATE/snapshot.json"
run_revive save >/dev/null
assert_jq "$HC_REVIVE_STATE/snapshot.json" '([.terminals[] | select(.terminal == "t1" and .legacy and .collision)] | length) == 2
 and (.terminals | any(.terminal == "t2" and .seen == 0))' 'ambiguous scan erased a row or aged sibling evidence'
pass 'ambiguous remote scan retains both sessions and preserves previously saved siblings'

new_case local_checkpoint
configure_local_agent
run_revive save >/dev/null
: > "$HC_FIXTURES/fail-checkpoint"
if run_revive restore; then fail 'failed local completion checkpoint reported success'; fi
assert_jq "$HC_REVIVE_STATE/pending.json" '.terminals[0].delivery.state == "attempting"' 'local dispatch lacked durable evidence'
awk '/^sync$/{synced=NR} /^mv pending.json$/{marked=NR} /^send t1$/{ok=marked && marked<synced && synced<NR} END{exit !ok}' "$HC_EVENT_LOG" || fail 'local send preceded durable marker'
rm "$HC_FIXTURES/fail-checkpoint"
run_revive restore
run_revive tick
assert_eq "$(wc -l < "$HC_SEND_ATTEMPTS" | tr -d ' ')" 1 'manual or automatic replayed a local send'
assert_jq "$HC_REVIVE_STATE/pending.json" '.terminals | length == 1 and .[0].delivery.state == "attempting"' 'local attempt evidence changed'
pass 'local completion failure suppresses replay from both manual restore and tick'

new_case scheduled_slow
mkdir -p "$HC_REVIVE_STATE"
jq -n --arg core "$core_a" '{machines:[{name:"slow",id:$core,state:"connected"}]}' > "$HC_FIXTURES/machines.json"
print '{"terminals":[{"address":"slow/t1"},{"address":"slow/t2"},{"address":"slow/t3"}]}' > "$HC_FIXTURES/ls.json"
for terminal in t1 t2 t3; do
  write_get "slow/$terminal" "{\"address\":\"slow/$terminal\",\"state\":\"live\",\"keep\":true,\"pid\":100,\"foreground\":null}"
done
jq -n --arg core "$core_a" --arg id "$session_1" '{version:2,terminals:[
 range(1;4) | {machine:$core,terminal:("t"+tostring),cwd:"/work",agent:"codex",session:$id}]}' > "$HC_REVIVE_STATE/pending.json"
: > "$HC_FIXTURES/hold.slow__t2"
assert_eq "$(run_revive schedule tick)" started 'worker startup handshake'
for _ in {1..1000}; do [[ -e "$HC_FIXTURES/holding.slow__t2" ]] && break; /bin/sleep 0.01; done
[[ -e "$HC_FIXTURES/holding.slow__t2" ]] || fail 'worker never reached slow helper'
assert_jq "$HC_REVIVE_STATE/pending.json" '.terminals | length == 2 and .[0].terminal == "t2" and .[0].delivery.state == "attempting" and .[1].terminal == "t3" and .[1].delivery == null' 'in-flight worker lost or repeated pending work'
assert_eq "$(run_revive schedule tick)" busy 'second window started another worker'
: > "$HC_FIXTURES/release.slow__t2"
for _ in {1..1000}; do [[ ! -f "$HC_REVIVE_STATE/pending.json" ]] && break; /bin/sleep 0.01; done
[[ ! -f "$HC_REVIVE_STATE/pending.json" ]] || fail 'worker did not finish'
assert_eq "$(cut -f1 "$HC_SENDS")" $'slow/t1\nslow/t2\nslow/t3' 'overlapping window duplicated or skipped a dispatch'
if HC_REVIVE_STATE="$HC_FIXTURES/ls.json" run_revive schedule tick; then fail 'failed startup was acknowledged'; fi
pass 'UI launch returns during a blocked remote helper and a second window preserves progress'

new_case worker_deadline
mkdir -p "$HC_REVIVE_STATE"
configure_local_agent
jq -n --arg id "$session_1" '{version:2,terminals:[
  {machine:null,terminal:"t1",cwd:"/work",agent:"codex",session:$id}]}' > "$HC_REVIVE_STATE/pending.json"
: > "$HC_FIXTURES/hang.t1"
# A private fixture group models a UI runtime canceling its entire exec group.
HC_REVIVE_WORKER_SECONDS=4 /usr/bin/perl -MPOSIX -e '
  my $session = POSIX::setsid();
  defined($session) && $session == $$ or die "setsid: $!";
  system(@ARGV) == 0 or exit 1;
  sleep 30;
' /bin/zsh "$script" schedule tick > "$HC_FIXTURES/ui-ack" &
launcher=$!
for _ in {1..400}; do [[ -s "$HC_FIXTURES/ui-ack" ]] && break; /bin/sleep 0.01; done
assert_eq "$(<"$HC_FIXTURES/ui-ack")" started 'watchdog startup'
kill -KILL -- "-$launcher"
wait "$launcher" 2>/dev/null || true
for _ in {1..400}; do [[ -s "$HC_FIXTURES/hung.t1" ]] && break; /bin/sleep 0.01; done
[[ -s "$HC_FIXTURES/hung.t1" ]] || fail 'send did not reach the stalled helper'
read -r helper child < "$HC_FIXTURES/hung.t1"
assert_eq "$(run_revive schedule tick)" busy 'overlap during hung dispatch'
for _ in {1..500}; do
  if ! kill -0 "$helper" 2>/dev/null && ! kill -0 "$child" 2>/dev/null; then break; fi
  /bin/sleep 0.02
done
if kill -0 "$helper" 2>/dev/null || kill -0 "$child" 2>/dev/null; then fail 'hung helper or descendant survived deadline'; fi
wait_worker timed_out
assert_jq "$HC_REVIVE_STATE/pending.json" '.terminals[0].delivery.state == "attempting"' 'watchdog lost in-flight attempt'
assert_eq "$(run_revive schedule tick)" started 'watchdog failed to release lock'
wait_worker succeeded
assert_eq "$(wc -l < "$HC_SEND_ATTEMPTS" | tr -d ' ')" 1 'timed-out dispatch replayed'
pass 'independent watchdog kills a stuck helper and its descendant, releases lock, and preserves attempt'

for scenario in crash superseded; do
  new_case "worker_$scenario"
  mkdir -p "$HC_REVIVE_STATE"
  configure_local_agent
  jq -n --arg id "$session_1" '{version:2,terminals:[
    {machine:null,terminal:"t1",cwd:"/work",agent:"codex",session:$id}]}' > "$HC_REVIVE_STATE/pending.json"
  : > "$HC_FIXTURES/hang.t1"
  assert_eq "$(run_revive schedule tick)" started 'worker did not acknowledge'
  for _ in {1..500}; do [[ -s $HC_FIXTURES/hung.t1 ]] && break; /bin/sleep 0.02; done
  read -r helper child < "$HC_FIXTURES/hung.t1" || fail 'helper never reached send'
  worker=$(jq -er '.pid | select(. > 1)' "$HC_REVIVE_STATE/worker.json")
  run=$(jq -er '.run' "$HC_REVIVE_STATE/worker.json")
  if [[ $scenario == superseded ]]; then : > "$HC_FIXTURES/pause-finish.$run"; fi
  kill -KILL "$worker"

  if [[ $scenario == superseded ]]; then
    for _ in {1..500}; do [[ -s $HC_FIXTURES/finalizer-waiting ]] && break; /bin/sleep 0.02; done
    [[ -s $HC_FIXTURES/finalizer-waiting ]] || fail 'old finalizer never reached lock'
    finalizer=$(<"$HC_FIXTURES/finalizer-waiting")
  else
    wait_worker failed
    assert_eq "$(jq -r .run "$HC_REVIVE_STATE/worker.json")" "$run" 'crash attributed to wrong run'
  fi
  for pid in "$helper" "$child"; do
    for _ in {1..200}; do kill -0 "$pid" 2>/dev/null || break; /bin/sleep 0.02; done
    if kill -0 "$pid" 2>/dev/null; then fail 'helper survived worker crash'; fi
  done
  assert_jq "$HC_REVIVE_STATE/pending.json" '.terminals[0].delivery.state == "attempting"' 'crash lost attempt marker'
  assert_eq "$(run_revive schedule tick)" started 'crash held lock'
  wait_worker succeeded
  assert_eq "$(wc -l < "$HC_SEND_ATTEMPTS" | tr -d ' ')" 1 'crash replayed send'
  if [[ $scenario == superseded ]]; then
    newer=$(<"$HC_REVIVE_STATE/worker.json")
    [[ $(jq -r .run <<< "$newer") != "$run" ]] || fail 'run ID reused'
    : > "$HC_FIXTURES/release-finalizer"
    for _ in {1..500}; do kill -0 "$finalizer" 2>/dev/null || break; /bin/sleep 0.02; done
    if kill -0 "$finalizer" 2>/dev/null; then fail 'old finalizer did not exit'; fi
    assert_eq "$(<"$HC_REVIVE_STATE/worker.json")" "$newer" 'old finalizer overwrote a newer run'
    pass 'an old crash finalizer racing lock acquisition preserves the newer completion'
  else
    pass 'post-ack worker SIGKILL promptly publishes failure, kills helpers, releases lock and prevents replay'
  fi
done

new_case worker_failure
configure_local_agent
run_revive save >/dev/null
prior=$(<"$HC_REVIVE_STATE/snapshot.json")
jq -n --arg id "$session_2" '{cwd:"/new",sessionId:$id}' > "$HOME/.claude/sessions/200.json"
assert_eq "$(HC_FAIL_SNAPSHOT_MV=1 run_revive schedule save)" started 'save never acknowledged'
wait_worker failed
assert_eq "$(<"$HC_REVIVE_STATE/snapshot.json")" "$prior" 'failed save changed snapshot'
assert_eq "$(stat -f %Lp "$HC_REVIVE_STATE/worker.json")" 600 'worker record permissions'
node - "${0:A:h}/mods/agent-revive/main.js" "$HC_REVIVE_STATE/worker.json" <<'NODE' || fail 'worker failure hidden in UI'
const fs = require("fs");
const vm = require("vm");
const source = fs.readFileSync(process.argv[2], "utf8");
const state = require("path").dirname(process.argv[3]);
let refresh, label;
const element = new Proxy({}, { get: (_, key) => (...args) => {
  if (key === "child" && typeof args[0] === "string") label = args[0];
  return element;
}});
const context = {
  View: class {}, home: () => "", theme: () => ({}), div: () => element, h_flex: () => element,
  readTextFile: (path) => fs.promises.readFile(state + "/" + path.split("/").pop(), "utf8"),
};
vm.runInNewContext(source.slice(source.indexOf("const uuid ="))
  .replace("export default class AgentRevive", "globalThis.AgentRevive = class"), context);
const status = context.workerStatus;
const running = {status:"running", run:"a".repeat(32)};
if (status(running, 1e12) !== "recovery in progress" || status(running, 0) !== "recovery in progress"
    || status({status:"timed_out"}, 0) !== "recovery worker timed out"
    || status({...running, priorFailure:true}, 80) !== "retrying failed recovery"
    || status({status:"succeeded", finished:50}, 500) !== "recovery status is stale"
    || status({status:"succeeded", finished:50}, 55) !== null) process.exit(1);
const view = new context.AgentRevive();
view.refreshId = 0;
view.tick(null, { spawn: (callback) => { refresh = callback({ notify() {} }); } });
refresh.then(() => {
  view.render();
  if (view.saved.actionable !== 1 || label !== "↻ recovery worker failed") process.exit(1);
}).catch(error => { console.error(error); process.exit(1); });
NODE
assert_eq "$(run_revive schedule tick)" started 'retry did not acquire lock'
wait_worker succeeded
assert_jq "$HC_REVIVE_STATE/snapshot.json" '.terminals[0].cwd == "/new"' 'recent snapshot masked failed refresh'
pass 'post-acknowledgement publication failure reaches the UI and forces a fresh retry'

# A malformed pending file must stop the tick without being rewritten or erased.
new_case malformed_pending
mkdir -p "$HC_REVIVE_STATE"
print -r -- "{\"version\":2,\"boot\":\"$local_boot\",\"machines\":{},\"terminals\":[]}" > "$HC_REVIVE_STATE/snapshot.json"
print -r -- '{"version":2,"terminals":"not-an-array"}' > "$HC_REVIVE_STATE/pending.json"
cp "$HC_REVIVE_STATE/pending.json" "$HC_FIXTURES/pending.before"
run_revive tick
cmp -s "$HC_FIXTURES/pending.before" "$HC_REVIVE_STATE/pending.json" || fail 'malformed pending was rewritten or erased'
assert_eq "$(stat -f %Lp "$HC_REVIVE_STATE/pending.json")" 600 'malformed pending permissions'
[[ ! -s $HC_SENDS ]] || fail 'malformed pending caused a send'
pass 'malformed pending remains intact and inert'

# Two aliases for one permanent core cause one scan and one stable entry.
new_case duplicate_aliases
print -r -- "{\"machines\":[
 {\"name\":\"old-a\",\"id\":\"$core_a\",\"state\":\"connected\",\"temporary\":false},
 {\"name\":\"new-a\",\"id\":\"$core_a\",\"state\":\"connected\",\"temporary\":false}]}" > "$HC_FIXTURES/machines.json"
print '{"terminals":[{"address":"new-a/t1"},{"address":"old-a/t1"}]}' > "$HC_FIXTURES/ls.json"
print -r -- "{\"boot\":\"$boot_a1\",\"terminals\":[{\"terminal\":\"t1\",\"cwd\":\"/srv/a b\",\"agent\":\"codex\",\"session\":\"$session_1\"}]}" > "$HC_FIXTURES/scan.new-a"
print -r -- "{\"boot\":\"$boot_a1\",\"terminals\":[{\"terminal\":\"t1\",\"cwd\":\"/wrong\",\"agent\":\"codex\",\"session\":\"$session_2\"}]}" > "$HC_FIXTURES/scan.old-a"
run_revive save >/dev/null
assert_jq "$HC_REVIVE_STATE/snapshot.json" ".machines[\"$core_a\"] == \"$boot_a1\" and (.terminals | length) == 1" 'duplicate alias snapshot'
assert_jq "$HC_REVIVE_STATE/snapshot.json" ".terminals[0] | .machine == \"$core_a\" and .terminal == \"t1\" and (has(\"address\") | not) and (has(\"cmd\") | not)" 'alias or command persisted'
scans=$(awk '/^exec .*remote-scan/{n++} END{print n+0}' "$HC_CALLS")
assert_eq "$scans" 1 'duplicate aliases scanned more than once'
pass 'duplicate aliases are deduplicated by permanent core ID'

# Separate permanent IDs remain separate even with the same boot ID and terminal suffix.
new_case alias_separation
print -r -- "{\"machines\":[
 {\"name\":\"box-a\",\"id\":\"$core_a\",\"state\":\"connected\"},
 {\"name\":\"box-b\",\"id\":\"$core_b\",\"state\":\"connected\"}]}" > "$HC_FIXTURES/machines.json"
print '{"terminals":[{"address":"box-a/t1"},{"address":"box-b/t1"}]}' > "$HC_FIXTURES/ls.json"
print -r -- "{\"boot\":\"$boot_a1\",\"terminals\":[{\"terminal\":\"t1\",\"cwd\":\"/a\",\"agent\":\"codex\",\"session\":\"$session_1\"}]}" > "$HC_FIXTURES/scan.box-a"
print -r -- "{\"boot\":\"$boot_a1\",\"terminals\":[{\"terminal\":\"t1\",\"cwd\":\"/b\",\"agent\":\"claude\",\"session\":\"$session_2\"}]}" > "$HC_FIXTURES/scan.box-b"
run_revive save >/dev/null
assert_jq "$HC_REVIVE_STATE/snapshot.json" ".machines[\"$core_a\"] == \"$boot_a1\"
  and .machines[\"$core_b\"] == \"$boot_a1\"
  and (.terminals | length == 2)
  and (.terminals | any(.machine == \"$core_a\" and .terminal == \"t1\" and .session == \"$session_1\"))
  and (.terminals | any(.machine == \"$core_b\" and .terminal == \"t1\" and .session == \"$session_2\"))" 'different core IDs were conflated by boot or terminal suffix'
scans=$(awk '/^exec .*remote-scan/{n++} END{print n+0}' "$HC_CALLS")
assert_eq "$scans" 2 'different core IDs were not scanned independently'
pass 'permanent core IDs keep equal boots and terminal suffixes separate'

# Empty local discovery preserves local history, while a successful empty remote scan can age its core.
new_case mixed_empty_discovery
print -r -- "{\"machines\":[
 {\"name\":\"box-a\",\"id\":\"$core_a\",\"state\":\"connected\"},
 {\"name\":\"box-b\",\"id\":\"$core_b\",\"state\":\"connected\"}]}" > "$HC_FIXTURES/machines.json"
print '{"terminals":[{"address":"box-a/t9"},{"address":"box-b/t2"}]}' > "$HC_FIXTURES/ls.json"
print -r -- "{\"boot\":\"$boot_a1\",\"terminals\":[{\"terminal\":\"t9\",\"cwd\":\"/new\",\"agent\":\"agy\",\"session\":\"$session_1\"}]}" > "$HC_FIXTURES/scan.box-a"
print -r -- "{\"boot\":\"$boot_b1\",\"terminals\":[]}" > "$HC_FIXTURES/scan.box-b"
mkdir -p "$HC_REVIVE_STATE"
print -r -- "{\"version\":2,\"boot\":\"$local_boot\",\"machines\":{\"$core_a\":\"$boot_a1\",\"$core_b\":\"$boot_b1\"},\"terminals\":[
 {\"machine\":null,\"terminal\":\"t1\",\"cwd\":\"/local\",\"agent\":\"codex\",\"session\":\"$session_1\",\"seen\":0},
 {\"machine\":\"$core_b\",\"terminal\":\"t2\",\"cwd\":\"/old-b\",\"agent\":\"claude\",\"session\":\"$session_2\",\"seen\":0}]}" > "$HC_REVIVE_STATE/snapshot.json"
run_revive save >/dev/null
assert_jq "$HC_REVIVE_STATE/snapshot.json" ".terminals | length == 2
  and any(.machine == null and .terminal == \"t1\" and .seen == 0)
  and any(.machine == \"$core_a\" and .terminal == \"t9\")
  and all(.machine != \"$core_b\")" 'empty local or successful empty remote discovery used the wrong retention rule'
pass 'empty local discovery is preserved while successful remote emptiness ages normally'

# A local discovery failure must leave the whole existing snapshot unchanged.
new_case local_discovery_failure
print '{"terminals":[{"address":"t1"}]}' > "$HC_FIXTURES/ls.json"
write_get t1 '{"address":"t1","state":"live","keep":true,"pid":100,"foreground":null}'
print '100 ttys001 zsh\n200 ttys001 codex' > "$HC_FIXTURES/ps.txt"
print 1 > "$HC_FIXTURES/status.lsof"
mkdir -p "$HC_REVIVE_STATE"
print -r -- "{\"version\":2,\"boot\":\"$local_boot\",\"machines\":{},\"terminals\":[
 {\"machine\":null,\"terminal\":\"t9\",\"cwd\":\"/old\",\"agent\":\"codex\",\"session\":\"$session_1\",\"seen\":0}]}" > "$HC_REVIVE_STATE/snapshot.json"
cp "$HC_REVIVE_STATE/snapshot.json" "$HC_FIXTURES/snapshot.before"
if run_revive save >/dev/null 2>&1; then fail 'failed lsof was treated as empty local discovery'; fi
cmp -s "$HC_FIXTURES/snapshot.before" "$HC_REVIVE_STATE/snapshot.json" || fail 'local discovery failure rewrote the snapshot'
pass 'local discovery errors leave the snapshot unchanged'

# One noisy core fails as a unit without affecting a valid sibling or aging its old record.
new_case sibling_failure
print -r -- "{\"machines\":[
 {\"name\":\"new-a\",\"id\":\"$core_a\",\"state\":\"connected\"},
 {\"name\":\"box-b\",\"id\":\"$core_b\",\"state\":\"connected\"}]}" > "$HC_FIXTURES/machines.json"
print '{"terminals":[{"address":"new-a/t9"},{"address":"box-b/t2"}]}' > "$HC_FIXTURES/ls.json"
print -r -- "{\"boot\":\"$boot_a1\",\"terminals\":[{\"terminal\":\"t9\",\"cwd\":\"/new\",\"agent\":\"agy\",\"session\":\"$session_1\"}]}" > "$HC_FIXTURES/scan.new-a"
print -r -- "notice\n{\"boot\":\"$boot_b1\",\"terminals\":[]}" > "$HC_FIXTURES/scan.box-b"
mkdir -p "$HC_REVIVE_STATE"
print -r -- "{\"version\":2,\"boot\":\"$local_boot\",\"machines\":{\"$core_a\":\"$boot_a1\",\"$core_b\":\"$boot_b1\"},\"terminals\":[
 {\"machine\":\"$core_a\",\"terminal\":\"t1\",\"cwd\":\"/old-a\",\"agent\":\"codex\",\"session\":\"$session_1\",\"seen\":0},
 {\"machine\":\"$core_b\",\"terminal\":\"t2\",\"cwd\":\"/old-b\",\"agent\":\"claude\",\"session\":\"$session_2\",\"seen\":0}]}" > "$HC_REVIVE_STATE/snapshot.json"
run_revive save >/dev/null
assert_jq "$HC_REVIVE_STATE/snapshot.json" ".terminals | any(.machine == \"$core_a\" and .terminal == \"t9\")" 'valid sibling did not update'
assert_jq "$HC_REVIVE_STATE/snapshot.json" ".terminals | any(.machine == \"$core_b\" and .terminal == \"t2\" and .seen == 0)" 'failed core was aged or erased'
assert_jq "$HC_REVIVE_STATE/snapshot.json" ".machines[\"$core_b\"] == \"$boot_b1\"" 'failed core baseline changed'
pass 'invalid remote output fails only that core and preserves its state'

# A changed core merges into pending before its baseline advances; an unavailable sibling is untouched.
new_case changed_boot
print -r -- "{\"machines\":[
 {\"name\":\"new-a\",\"id\":\"$core_a\",\"state\":\"connected\"},
 {\"name\":\"box-b\",\"id\":\"$core_b\",\"state\":\"connected\"}]}" > "$HC_FIXTURES/machines.json"
print '{"terminals":[{"address":"new-a/t1"},{"address":"box-b/t2"}]}' > "$HC_FIXTURES/ls.json"
print -r -- "$boot_a2" > "$HC_FIXTURES/boot.new-a"
mkdir -p "$HC_REVIVE_STATE"
print -r -- "{\"version\":2,\"boot\":\"$local_boot\",\"machines\":{\"$core_a\":\"$boot_a1\",\"$core_b\":\"$boot_b1\"},\"terminals\":[
 {\"machine\":\"$core_a\",\"terminal\":\"t1\",\"cwd\":\"/a\",\"agent\":\"codex\",\"session\":\"$session_1\",\"seen\":0},
 {\"machine\":\"$core_b\",\"terminal\":\"t2\",\"cwd\":\"/b\",\"agent\":\"claude\",\"session\":\"$session_2\",\"seen\":0}]}" > "$HC_REVIVE_STATE/snapshot.json"
print -r -- "{\"version\":2,\"tries\":3,\"baseline\":{\"machines\":{}},\"terminals\":[
 {\"machine\":\"$core_c\",\"terminal\":\"t7\",\"cwd\":\"/c\",\"agent\":\"agy\",\"session\":\"$session_2\",\"seen\":0,\"tries\":3}]}" > "$HC_REVIVE_STATE/pending.json"
old_mtime "$HC_REVIVE_STATE/snapshot.json"
run_revive tick
assert_jq "$HC_REVIVE_STATE/pending.json" ".terminals | any(.machine == \"$core_a\") and any(.machine == \"$core_c\") and (all(.machine != \"$core_b\"))" 'pending merge selected wrong cores'
assert_jq "$HC_REVIVE_STATE/pending.json" ".terminals[] | select(.machine == \"$core_a\") | .tries == 0" 'unavailable changed core consumed a retry'
assert_jq "$HC_REVIVE_STATE/snapshot.json" ".machines[\"$core_a\"] == \"$boot_a2\" and .machines[\"$core_b\"] == \"$boot_b1\"" 'per-core baselines wrong'
assert_jq "$HC_REVIVE_STATE/snapshot.json" ".terminals | any(.machine == \"$core_b\" and .seen == 0)" 'unavailable sibling snapshot changed'
pending_line=$(awk '/pending.json/{print NR; exit}' "$HC_MV_LOG")
snapshot_line=$(awk '/snapshot.json/{print NR; exit}' "$HC_MV_LOG")
(( pending_line < snapshot_line )) || fail 'snapshot baseline moved before pending'
pending_event=$(awk '/^mv pending.json$/{print NR; exit}' "$HC_EVENT_LOG")
sync_event=$(awk '/^sync$/{n++; if (n == 1) {print NR; exit}}' "$HC_EVENT_LOG")
snapshot_event=$(awk '/^mv snapshot.json$/{print NR; exit}' "$HC_EVENT_LOG")
snapshot_sync_event=$(awk '/^sync$/{n++; if (n == 2) {print NR; exit}}' "$HC_EVENT_LOG")
pending_clear_event=$(awk '/^mv pending.json$/{n++; if (n == 2) {print NR; exit}}' "$HC_EVENT_LOG")
(( pending_event < sync_event && sync_event < snapshot_event
  && snapshot_event < snapshot_sync_event && snapshot_sync_event < pending_clear_event )) \
  || fail 'deferred baseline durability order is wrong'
assert_eq "$(stat -f %Lp "$HC_REVIVE_STATE/pending.json")" 600 'pending permissions'
[[ ! -s $HC_SENDS ]] || fail 'unavailable terminals triggered a send'
pass 'changed boot queues only that core before advancing its baseline'

# Simulate a crash-window snapshot rename failure: pending remains durable and baseline stays old.
new_case atomic_failure
print -r -- "{\"machines\":[{\"name\":\"new-a\",\"id\":\"$core_a\",\"state\":\"connected\"}]}" > "$HC_FIXTURES/machines.json"
print '{"terminals":[{"address":"new-a/t1"}]}' > "$HC_FIXTURES/ls.json"
print -r -- "$boot_a2" > "$HC_FIXTURES/boot.new-a"
mkdir -p "$HC_REVIVE_STATE"
print -r -- "{\"version\":2,\"boot\":\"$local_boot\",\"machines\":{\"$core_a\":\"$boot_a1\"},\"terminals\":[
 {\"machine\":\"$core_a\",\"terminal\":\"t1\",\"cwd\":\"/a\",\"agent\":\"codex\",\"session\":\"$session_1\",\"seen\":0}]}" > "$HC_REVIVE_STATE/snapshot.json"
old_mtime "$HC_REVIVE_STATE/snapshot.json"
export HC_FAIL_SNAPSHOT_MV=1
run_revive tick
assert_jq "$HC_REVIVE_STATE/pending.json" ".terminals | any(.machine == \"$core_a\")" 'pending was not durable after snapshot rename failure'
assert_jq "$HC_REVIVE_STATE/pending.json" ".baseline.machines[\"$core_a\"] == \"$boot_a2\"" 'pending lost deferred baseline'
assert_jq "$HC_REVIVE_STATE/snapshot.json" ".machines[\"$core_a\"] == \"$boot_a1\"" 'failed snapshot rename advanced baseline'
pass 'pending survives an interrupted baseline advance'

# If the post-snapshot durability barrier fails, the snapshot may already carry
# the new baseline but pending must retain the deferred baseline for idempotent replay.
new_case snapshot_sync_failure
print -r -- "{\"machines\":[{\"name\":\"new-a\",\"id\":\"$core_a\",\"state\":\"connected\"}]}" > "$HC_FIXTURES/machines.json"
print '{"terminals":[{"address":"new-a/t1"}]}' > "$HC_FIXTURES/ls.json"
print -r -- "$boot_a2" > "$HC_FIXTURES/boot.new-a"
mkdir -p "$HC_REVIVE_STATE"
print -r -- "{\"version\":2,\"boot\":\"$local_boot\",\"machines\":{\"$core_a\":\"$boot_a1\"},\"terminals\":[
 {\"machine\":\"$core_a\",\"terminal\":\"t1\",\"cwd\":\"/a\",\"agent\":\"codex\",\"session\":\"$session_1\",\"seen\":0}]}" > "$HC_REVIVE_STATE/snapshot.json"
old_mtime "$HC_REVIVE_STATE/snapshot.json"
export HC_FAIL_SYNC_AT=2
run_revive tick
assert_jq "$HC_REVIVE_STATE/snapshot.json" ".machines[\"$core_a\"] == \"$boot_a2\"" 'snapshot did not reach the post-rename sync point'
assert_jq "$HC_REVIVE_STATE/pending.json" ".baseline.machines[\"$core_a\"] == \"$boot_a2\"
  and (.terminals | any(.machine == \"$core_a\" and .terminal == \"t1\"))" 'failed snapshot sync cleared deferred recovery state'
assert_eq "$(/bin/cat "$HC_SYNC_COUNT")" 2 'snapshot sync failure occurred at the wrong barrier'
pending_moves=$(awk '/pending.json/{n++} END{print n+0}' "$HC_MV_LOG")
assert_eq "$pending_moves" 1 'pending baseline was cleared after snapshot sync failure'
[[ ! -s $HC_SEND_ATTEMPTS ]] || fail 'restore dispatched after snapshot sync failure'
pass 'failed post-snapshot sync preserves the deferred baseline'

# Resolve an alias rename at restore time; busy/no-keep never send, and raw cmd is ignored.
new_case restore_routing
print -r -- "{\"machines\":[
 {\"name\":\"old-a\",\"id\":\"$core_a\",\"state\":\"unreachable\"},
 {\"name\":\"new-a\",\"id\":\"$core_a\",\"state\":\"connected\"}]}" > "$HC_FIXTURES/machines.json"
print '{"terminals":[{"address":"new-a/t1"},{"address":"new-a/t2"},{"address":"new-a/t3"},{"address":"new-a/t4"},{"address":"new-a/t5"},{"address":"new-a/t6"}]}' > "$HC_FIXTURES/ls.json"
print -r -- "$boot_a2" > "$HC_FIXTURES/boot.new-a"
write_get new-a/t1 '{"address":"new-a/t1","state":"live","keep":true,"pid":100,"foreground":{"pid":200}}'
write_get new-a/t2 '{"address":"new-a/t2","state":"live","keep":true,"pid":101,"foreground":null}'
write_get new-a/t3 '{"address":"new-a/t3","state":"live","keep":false,"pid":102,"foreground":null}'
write_get new-a/t4 '{}'
write_get new-a/t5 '{"address":"new-a/t5","state":"live","keep":true,"pid":105,"foreground":null}'
write_get new-a/t6 '{"address":"new-a/t6","state":"live","keep":true,"pid":1.5,"foreground":{"pid":1.5}}'
mkdir -p "$HC_REVIVE_STATE"
print -r -- "{\"version\":2,\"boot\":\"$local_boot\",\"machines\":{\"$core_a\":\"$boot_a2\"},\"terminals\":[]}" > "$HC_REVIVE_STATE/snapshot.json"
print -r -- "{\"version\":2,\"tries\":0,\"baseline\":{\"machines\":{}},\"terminals\":[
 {\"machine\":\"$core_a\",\"terminal\":\"t1\",\"cwd\":\"/srv/a b\",\"agent\":\"codex\",\"session\":\"$session_1\",\"cmd\":\"touch /tmp/evil\",\"tries\":0},
 {\"machine\":\"$core_a\",\"terminal\":\"t2\",\"cwd\":\"/srv\",\"agent\":\"codex\",\"session\":\"bad;id\",\"tries\":0},
 {\"machine\":\"$core_a\",\"terminal\":\"t3\",\"cwd\":\"/srv\",\"agent\":\"claude\",\"session\":\"$session_2\",\"tries\":0},
 {\"machine\":\"$core_a\",\"terminal\":\"t4\",\"cwd\":\"/srv\",\"agent\":\"agy\",\"session\":\"$session_2\",\"tries\":2},
 {\"machine\":\"$core_a\",\"terminal\":\"t5\",\"cwd\":\"/srv\",\"agent\":\"codex\",\"session\":\"$session_1\",\"tries\":\"not-an-integer\"},
 {\"machine\":\"$core_a\",\"terminal\":\"t6\",\"cwd\":\"/srv\",\"agent\":\"claude\",\"session\":\"$session_2\",\"tries\":1}]}" > "$HC_REVIVE_STATE/pending.json"
run_revive tick
[[ ! -s $HC_SENDS ]] || fail 'busy, invalid, or no-keep entry sent data'
assert_jq "$HC_REVIVE_STATE/pending.json" '.terminals | length == 6
  and any(.terminal == "t1" and .tries == 1)
  and any(.terminal == "t2" and .tries == 0)
  and any(.terminal == "t3" and .tries == 0)
  and any(.terminal == "t4" and .tries == 2)
  and any(.terminal == "t5" and .tries == "not-an-integer")
  and any(.terminal == "t6" and .tries == 1)' 'busy/unavailable/untrusted retry accounting'
write_get new-a/t1 '{"address":"new-a/t1","state":"live","keep":true,"pid":100,"foreground":null}'
run_revive tick
assert_eq "$(wc -l < "$HC_SENDS" | tr -d ' ')" 1 'restore sent more than once'
send_line=$(<"$HC_SENDS")
[[ $send_line == $'new-a/t1\t'"cd '/srv/a b' && codex resume $session_1" ]] || fail "restore did not rebuild the safe command: $send_line"
[[ $send_line != *evil* && $send_line != old-a/* ]] || fail 'restore trusted stale alias or cmd'
assert_jq "$HC_REVIVE_STATE/pending.json" '.terminals | length == 5
  and any(.terminal == "t2" and .tries == 0)
  and any(.terminal == "t3" and .tries == 0)
  and any(.terminal == "t4" and .tries == 2)
  and any(.terminal == "t5" and .tries == "not-an-integer")
  and any(.terminal == "t6" and .tries == 1)' 'successful entry not removed independently'
pass 'restore resolves live aliases, checks keep/shell, and rebuilds commands'

# Rebinding a trusted alias to another permanent core can never send the saved command.
new_case alias_rebind
print -r -- "{\"machines\":[{\"name\":\"new-a\",\"id\":\"$core_a\",\"state\":\"connected\"}]}" > "$HC_FIXTURES/machines.json"
print '{"terminals":[{"address":"new-a/t1"}]}' > "$HC_FIXTURES/ls.json"
print -r -- "$core_b" > "$HC_FIXTURES/id.new-a"
write_get new-a/t1 '{"address":"new-a/t1","state":"live","keep":true,"pid":100,"foreground":null}'
mkdir -p "$HC_REVIVE_STATE"
print -r -- "{\"version\":2,\"boot\":\"$local_boot\",\"machines\":{\"$core_a\":\"$boot_a1\"},\"terminals\":[]}" > "$HC_REVIVE_STATE/snapshot.json"
print -r -- "{\"version\":2,\"tries\":0,\"baseline\":{\"machines\":{}},\"terminals\":[
 {\"machine\":\"$core_a\",\"terminal\":\"t1\",\"cwd\":\"/srv\",\"agent\":\"codex\",\"session\":\"$session_1\",\"tries\":0}]}" > "$HC_REVIVE_STATE/pending.json"
run_revive tick
[[ ! -s $HC_SEND_ATTEMPTS ]] || fail 'alias rebind reached hc send on the replacement core'
assert_jq "$HC_REVIVE_STATE/pending.json" '.terminals[0].tries == 0 and (.terminals[0].delivery == null)' 'alias rebind consumed or obscured pending intent'
pass 'operation-time permanent-ID verification blocks alias rebind sends'

# A send failure is delivery-ambiguous: keep inert evidence and never retry it automatically.
new_case send_failure
print -r -- "{\"machines\":[{\"name\":\"new-a\",\"id\":\"$core_a\",\"state\":\"connected\"}]}" > "$HC_FIXTURES/machines.json"
print '{"terminals":[{"address":"new-a/t1"}]}' > "$HC_FIXTURES/ls.json"
write_get new-a/t1 '{"address":"new-a/t1","state":"live","keep":true,"pid":100,"foreground":null}'
print 1 > "$HC_FIXTURES/status.send.new-a__t1"
mkdir -p "$HC_REVIVE_STATE"
print -r -- "{\"version\":2,\"boot\":\"$local_boot\",\"machines\":{\"$core_a\":\"$boot_a1\"},\"terminals\":[]}" > "$HC_REVIVE_STATE/snapshot.json"
print -r -- "{\"version\":2,\"tries\":8,\"baseline\":{\"machines\":{}},\"terminals\":[
 {\"machine\":\"$core_a\",\"terminal\":\"t1\",\"cwd\":\"/srv\",\"agent\":\"codex\",\"session\":\"$session_1\",\"tries\":8}]}" > "$HC_REVIVE_STATE/pending.json"
run_revive tick
run_revive tick
assert_eq "$(wc -l < "$HC_SEND_ATTEMPTS" | tr -d ' ')" 1 'ambiguous send failure was retried'
[[ ! -s $HC_SENDS ]] || fail 'failed send was recorded as successful'
assert_jq "$HC_REVIVE_STATE/pending.json" '.terminals[0].tries == 8
  and .terminals[0].delivery.state == "delivery_unknown"' 'send failure consumed retry or lost ambiguity evidence'
pass 'send failure becomes delivery_unknown without retry or erasure'

# Even if the helper sent successfully, a lost outer hc exec acknowledgement must not duplicate it.
new_case outer_ambiguity
print -r -- "{\"machines\":[{\"name\":\"new-a\",\"id\":\"$core_a\",\"state\":\"connected\"}]}" > "$HC_FIXTURES/machines.json"
print '{"terminals":[{"address":"new-a/t1"}]}' > "$HC_FIXTURES/ls.json"
write_get new-a/t1 '{"address":"new-a/t1","state":"live","keep":true,"pid":100,"foreground":null}'
print 1 > "$HC_FIXTURES/status.restore.new-a"
mkdir -p "$HC_REVIVE_STATE"
print -r -- "{\"version\":2,\"boot\":\"$local_boot\",\"machines\":{\"$core_a\":\"$boot_a1\"},\"terminals\":[]}" > "$HC_REVIVE_STATE/snapshot.json"
print -r -- "{\"version\":2,\"tries\":0,\"baseline\":{\"machines\":{}},\"terminals\":[
 {\"machine\":\"$core_a\",\"terminal\":\"t1\",\"cwd\":\"/srv\",\"agent\":\"claude\",\"session\":\"$session_2\",\"tries\":0}]}" > "$HC_REVIVE_STATE/pending.json"
run_revive tick
run_revive tick
assert_eq "$(wc -l < "$HC_SENDS" | tr -d ' ')" 1 'lost outer acknowledgement caused a duplicate send'
assert_jq "$HC_REVIVE_STATE/pending.json" '.terminals[0].delivery.state == "delivery_unknown"' 'outer ambiguity was not retained for reconciliation'
pass 'outer transport ambiguity is fail-closed after at most one send'

# A failed durable precommit blocks dispatch completely.
new_case precommit_failure
print -r -- "{\"machines\":[{\"name\":\"new-a\",\"id\":\"$core_a\",\"state\":\"connected\"}]}" > "$HC_FIXTURES/machines.json"
print '{"terminals":[{"address":"new-a/t1"}]}' > "$HC_FIXTURES/ls.json"
write_get new-a/t1 '{"address":"new-a/t1","state":"live","keep":true,"pid":100,"foreground":null}'
mkdir -p "$HC_REVIVE_STATE"
print -r -- "{\"version\":2,\"boot\":\"$local_boot\",\"machines\":{\"$core_a\":\"$boot_a1\"},\"terminals\":[]}" > "$HC_REVIVE_STATE/snapshot.json"
print -r -- "{\"version\":2,\"tries\":0,\"baseline\":{\"machines\":{}},\"terminals\":[
 {\"machine\":\"$core_a\",\"terminal\":\"t1\",\"cwd\":\"/srv\",\"agent\":\"agy\",\"session\":\"$session_2\",\"tries\":0}]}" > "$HC_REVIVE_STATE/pending.json"
export HC_FAIL_SYNC=1
run_revive tick
[[ ! -s $HC_SEND_ATTEMPTS ]] || fail 'send ran after precommit sync failure'
restore_execs=$(awk '/ remote-restore$/{n++} END{print n+0}' "$HC_EVENT_LOG")
assert_eq "$restore_execs" 0 'remote helper ran after precommit sync failure'
pass 'failed precommit causes zero remote dispatches'

# A new reboot observation replaces stale actionable state but retains colliding inert evidence.
new_case pending_collision
print -r -- "{\"machines\":[{\"name\":\"new-a\",\"id\":\"$core_a\",\"state\":\"connected\"}]}" > "$HC_FIXTURES/machines.json"
print '{"terminals":[{"address":"new-a/t1"}]}' > "$HC_FIXTURES/ls.json"
print -r -- "$boot_a2" > "$HC_FIXTURES/boot.new-a"
mkdir -p "$HC_REVIVE_STATE"
print -r -- "{\"version\":2,\"boot\":\"$local_boot\",\"machines\":{\"$core_a\":\"$boot_a1\"},\"terminals\":[
 {\"machine\":\"$core_a\",\"terminal\":\"t1\",\"cwd\":\"/new\",\"agent\":\"claude\",\"session\":\"$session_2\",\"seen\":0}]}" > "$HC_REVIVE_STATE/snapshot.json"
print -r -- "{\"version\":2,\"boot\":\"$local_boot\",\"machines\":{\"$core_a\":\"$boot_a1\"},\"tries\":2,\"baseline\":{\"machines\":{}},\"terminals\":[
 {\"machine\":\"$core_a\",\"terminal\":\"t1\",\"cwd\":\"/old\",\"agent\":\"codex\",\"session\":\"$session_1\",\"tries\":2},
 {\"legacy\":true,\"machine\":\"$core_a\",\"terminal\":\"t1\",\"address\":\"new-a/t1\",\"cmd\":\"manual evidence\"}]}" > "$HC_REVIVE_STATE/pending.json"
run_revive tick
assert_jq "$HC_REVIVE_STATE/pending.json" '.boot == "'$local_boot'" and .machines["'$core_a'"] == "'$boot_a1'"
  and ([.terminals[] | select(.legacy != true and .machine == "'$core_a'" and .terminal == "t1")] | length) == 1
  and (.terminals | any(.legacy != true and .session == "'$session_2'" and .tries == 0))
  and (.terminals | all(.legacy == true or .session != "'$session_1'"))
  and (.terminals | any(.legacy == true and .cmd == "manual evidence"))' 'pending collision lost new state, metadata, or inert evidence'
pass 'new actionable session supersedes stale state while inert evidence remains'

# An absent identity is not the same as an explicit local identity. Corrupted v2 rows
# stay inert in both snapshot transition and pending restore paths.
new_case missing_machine_identity
print '{"terminals":[{"address":"t1"}]}' > "$HC_FIXTURES/ls.json"
write_get t1 '{"address":"t1","state":"live","keep":true,"pid":100,"foreground":null}'
mkdir -p "$HC_REVIVE_STATE"
print -r -- "{\"version\":2,\"boot\":\"old-local-boot\",\"machines\":{},\"terminals\":[
 {\"terminal\":\"t1\",\"cwd\":\"/srv\",\"agent\":\"codex\",\"session\":\"$session_1\",\"seen\":0}]}" > "$HC_REVIVE_STATE/snapshot.json"
print -r -- "{\"version\":2,\"tries\":0,\"baseline\":{\"machines\":{}},\"terminals\":[
 {\"terminal\":\"t1\",\"cwd\":\"/srv\",\"agent\":\"codex\",\"session\":\"$session_1\",\"tries\":0}]}" > "$HC_REVIVE_STATE/pending.json"
run_revive tick
[[ ! -s $HC_SEND_ATTEMPTS ]] || fail 'missing machine identity reached hc send'
assert_jq "$HC_REVIVE_STATE/snapshot.json" '(.terminals[0] | has("machine") | not)
  and .boot == "'$local_boot'"' 'missing-machine snapshot row was rebound or erased'
assert_jq "$HC_REVIVE_STATE/pending.json" '(.terminals[0] | has("machine") | not)
  and .terminals[0].tries == 0' 'missing-machine pending evidence was rebound, aged, or erased'
pass 'missing machine identity remains inert and causes zero sends'

# Control bytes that can edit a PTY line remain inert even when every other field is valid.
new_case control_cwd
print -r -- "{\"machines\":[{\"name\":\"new-a\",\"id\":\"$core_a\",\"state\":\"connected\"}]}" > "$HC_FIXTURES/machines.json"
print '{"terminals":[{"address":"new-a/t1"}]}' > "$HC_FIXTURES/ls.json"
write_get new-a/t1 '{"address":"new-a/t1","state":"live","keep":true,"pid":100,"foreground":null}'
mkdir -p "$HC_REVIVE_STATE"
print -r -- "{\"version\":2,\"boot\":\"$local_boot\",\"machines\":{\"$core_a\":\"$boot_a1\"},\"terminals\":[]}" > "$HC_REVIVE_STATE/snapshot.json"
jq -cn --arg machine "$core_a" --arg cwd $'/safe\u0015touch /tmp/evil' --arg session "$session_1" '
  {version:2,tries:0,baseline:{machines:{}},terminals:[
    {machine:$machine,terminal:"t1",cwd:$cwd,agent:"codex",session:$session,tries:0}]}' > "$HC_REVIVE_STATE/pending.json"
run_revive tick
[[ ! -s $HC_SEND_ATTEMPTS ]] || fail 'control-byte cwd reached hc send'
assert_jq "$HC_REVIVE_STATE/pending.json" '.terminals[0].cwd | contains("touch /tmp/evil")' 'control-byte evidence was erased'
pass 'PTY control bytes are rejected and retained as inert evidence'

# Any malformed permanent identity invalidates all remote activity and preserves pending retries.
new_case invalid_inventory
print -r -- "{\"machines\":[
 {\"name\":\"new-a\",\"id\":\"$core_a\",\"state\":\"connected\"},
 {\"name\":\"bad\",\"id\":\"not-a-core-id\",\"state\":\"connected\"}]}" > "$HC_FIXTURES/machines.json"
print '{"terminals":[{"address":"new-a/t1"},{"address":"bad/t1"}]}' > "$HC_FIXTURES/ls.json"
mkdir -p "$HC_REVIVE_STATE"
print -r -- "{\"version\":2,\"boot\":\"$local_boot\",\"machines\":{\"$core_a\":\"$boot_a1\"},\"terminals\":[
 {\"machine\":\"$core_a\",\"terminal\":\"t1\",\"cwd\":\"/a\",\"agent\":\"codex\",\"session\":\"$session_1\",\"seen\":0}]}" > "$HC_REVIVE_STATE/snapshot.json"
print -r -- "{\"version\":2,\"tries\":4,\"baseline\":{\"machines\":{}},\"terminals\":[
 {\"machine\":\"$core_a\",\"terminal\":\"t1\",\"cwd\":\"/a\",\"agent\":\"codex\",\"session\":\"$session_1\",\"tries\":4}]}" > "$HC_REVIVE_STATE/pending.json"
run_revive tick
assert_jq "$HC_REVIVE_STATE/snapshot.json" ".machines[\"$core_a\"] == \"$boot_a1\" and (.terminals[0].seen == 0)" 'invalid inventory changed remote snapshot'
assert_jq "$HC_REVIVE_STATE/pending.json" '.terminals[0].tries == 4' 'invalid inventory consumed retry'
[[ ! -s $HC_SENDS ]] || fail 'invalid inventory caused send'
execs=$(awk '/^exec /{n++} END{print n+0}' "$HC_CALLS")
assert_eq "$execs" 0 'invalid inventory caused remote exec'
pass 'malformed inventory fails closed for every remote core'

# One alias mapped to two permanent IDs invalidates the entire remote inventory for this tick.
new_case alias_conflict
print -r -- "{\"machines\":[
 {\"name\":\"dup\",\"id\":\"$core_a\",\"state\":\"connected\"},
 {\"name\":\"dup\",\"id\":\"$core_b\",\"state\":\"connected\"}]}" > "$HC_FIXTURES/machines.json"
print '{"terminals":[{"address":"dup/t1"}]}' > "$HC_FIXTURES/ls.json"
mkdir -p "$HC_REVIVE_STATE"
print -r -- "{\"version\":2,\"boot\":\"$local_boot\",\"machines\":{\"$core_a\":\"$boot_a1\",\"$core_b\":\"$boot_b1\"},\"terminals\":[
 {\"machine\":\"$core_a\",\"terminal\":\"t1\",\"cwd\":\"/a\",\"agent\":\"codex\",\"session\":\"$session_1\",\"seen\":0},
 {\"machine\":\"$core_b\",\"terminal\":\"t1\",\"cwd\":\"/b\",\"agent\":\"claude\",\"session\":\"$session_2\",\"seen\":0}]}" > "$HC_REVIVE_STATE/snapshot.json"
print -r -- "{\"version\":2,\"tries\":4,\"baseline\":{\"machines\":{}},\"terminals\":[
 {\"machine\":\"$core_a\",\"terminal\":\"t1\",\"cwd\":\"/a\",\"agent\":\"codex\",\"session\":\"$session_1\",\"tries\":3},
 {\"machine\":\"$core_b\",\"terminal\":\"t1\",\"cwd\":\"/b\",\"agent\":\"claude\",\"session\":\"$session_2\",\"tries\":4}]}" > "$HC_REVIVE_STATE/pending.json"
run_revive tick
assert_jq "$HC_REVIVE_STATE/snapshot.json" ".machines[\"$core_a\"] == \"$boot_a1\"
  and .machines[\"$core_b\"] == \"$boot_b1\"
  and (.terminals | all(.seen == 0))" 'alias conflict changed snapshot state'
assert_jq "$HC_REVIVE_STATE/pending.json" '.terminals | length == 2
  and any(.machine == "'$core_a'" and .tries == 3)
  and any(.machine == "'$core_b'" and .tries == 4)' 'alias conflict aged pending state'
[[ ! -s $HC_SENDS ]] || fail 'alias conflict caused a send'
execs=$(awk '/^exec /{n++} END{print n+0}' "$HC_CALLS")
assert_eq "$execs" 0 'alias conflict caused remote exec'
pass 'alias conflicts fail closed without remote aging or sends'

# The view distinguishes safe automatic work from manual-review evidence.
node - "${0:A:h}/mods/agent-revive/main.js" <<'NODE' || fail 'status summary or timeout logic'
const fs = require("fs");
const vm = require("vm");
const source = fs.readFileSync(process.argv[2], "utf8");
const start = source.indexOf("const uuid =");
const end = source.indexOf("export default class");
if (start < 0 || end <= start) process.exit(1);
const context = {};
vm.runInNewContext(`${source.slice(start, end)}
  globalThis.summary = pendingSummary;`, context);
const core = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const session1 = "11111111-1111-1111-1111-111111111111";
const session2 = "22222222-2222-2222-2222-222222222222";
const valid = (terminal, session) => ({ machine: core, terminal, cwd: "/srv",
  agent: "codex", session, tries: 0 });
const terminals = [
  valid("t1", session1),
  valid("t2", session1),
  valid("t2", session2),
  { ...valid("t3", session1), legacy: true },
  { ...valid("t4", session1), delivery: { state: "delivery_unknown" } },
  valid("t4", session2),
];
const result = context.summary({ version: 2, baseline: { machines: {} }, terminals });
if (result.total !== 6 || result.actionable !== 1 || result.review !== 5 || result.invalid) process.exit(1);
if (!context.summary({ terminals: "bad" }).invalid) process.exit(1);
if (!context.summary({ version: 1, terminals }).invalid) process.exit(1);
if (!context.summary({ version: 2, baseline: { machines: [] }, terminals }).invalid) process.exit(1);
if (!context.summary({ version: 2, machines: { [core]: "bad-boot" }, terminals }).invalid) process.exit(1);
if (!source.includes('"schedule", command') || source.includes("commandTimeout")) process.exit(1);
if (!source.includes("pending state needs review") || !source.includes("Manual-review records are not retried")) process.exit(1);
NODE
pass 'status separates actionable and review records and schedules the controller'

# Saved status validates its own v2 envelope and never presents inert or malformed rows
# as agents that can resume.
node - "${0:A:h}/mods/agent-revive/main.js" <<'NODE' || fail 'saved-state status validation'
const fs = require("fs");
const vm = require("vm");
const source = fs.readFileSync(process.argv[2], "utf8");
const start = source.indexOf("const uuid =");
const end = source.indexOf("export default class");
if (start < 0 || end <= start) process.exit(1);
const context = {};
vm.runInNewContext(`${source.slice(start, end)}
  globalThis.saved = savedSummary;
  globalThis.status = savedStatus;`, context);
const coreA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const coreB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const boot = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
const session1 = "11111111-1111-1111-1111-111111111111";
const session2 = "22222222-2222-2222-2222-222222222222";
const valid = (machine, terminal, session) => ({ machine, terminal, cwd: "/srv",
  agent: "codex", session, seen: 1 });
const terminals = [
  valid(coreA, "t1", session1),
  valid(coreA, "t2", session1),
  valid(coreA, "t2", session2),
  { ...valid(coreA, "t3", session1), legacy: true },
  valid(coreB, "t4", session1),
  { ...valid(null, "t5", session1), cwd: "/bad\u0001cwd" },
  { terminal: "t6", cwd: "/srv", agent: "codex", session: session1, seen: 1 },
];
const result = context.saved({ version: 2, boot: 123, machines: { [coreA]: boot }, terminals });
if (result.total !== 7 || result.actionable !== 1 || result.review !== 6
    || result.invalid || result.missing) process.exit(1);
if (context.status(result) !== "1 agent saved; 6 saved entries need review") process.exit(1);
if (context.status({ missing: true, invalid: false, actionable: 0, review: 0 }) !== "no agents saved") process.exit(1);
if (context.status({ missing: false, invalid: true, actionable: 0, review: 0 }) !== "saved state needs review") process.exit(1);
if (context.status({ missing: false, invalid: false, actionable: 0, review: 1 }) !== "1 saved entry needs review") process.exit(1);
if (context.status({ missing: false, invalid: false, actionable: 0, review: 0 }) !== "0 agents saved") process.exit(1);
const empty = { version: 2, boot: "local-boot", machines: {}, terminals: [] };
if (context.saved(empty).invalid || context.saved(empty).actionable !== 0) process.exit(1);
if (!context.saved({ ...empty, version: 1 }).invalid) process.exit(1);
if (!context.saved({ ...empty, boot: null }).invalid) process.exit(1);
if (!context.saved({ ...empty, machines: { [coreA]: "bad-boot" } }).invalid) process.exit(1);
if (!context.saved({ ...empty, terminals: "bad" }).invalid) process.exit(1);
NODE
pass 'saved status validates v2 and separates resumable from review-only rows'

print -- "$tests offline hc-revive tests passed"
