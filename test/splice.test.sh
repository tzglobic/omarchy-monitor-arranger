#!/bin/bash
# Exercises bin/omarchy-monitor-arranger against a throwaway config.
# Run with: bash test/splice.test.sh

set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BIN="$HERE/../bin/omarchy-monitor-arranger"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export OMARCHY_MONITORS_LUA="$WORK/monitors.lua"
export OMARCHY_ARRANGER_BACKUPS="$WORK/backups"
# Keep the test off the live compositor.
export PATH="$WORK/stub:$PATH"
mkdir -p "$WORK/stub"
printf '#!/bin/bash\nexit 0\n' >"$WORK/stub/hyprctl"
chmod +x "$WORK/stub/hyprctl"

failures=0
check() {
  local name="$1" expected="$2" actual="$3"
  [[ $expected == "$actual" ]] && return
  failures=$((failures + 1))
  echo "FAIL $name"
  echo "  expected: $expected"
  echo "  actual:   $actual"
}
ok() {
  local name="$1"
  shift
  "$@" && return
  failures=$((failures + 1))
  echo "FAIL $name"
}

block() {
  cat <<BLOCK
-- >>> omarchy-monitor-arranger >>>
-- Generated $1
hl.monitor({ output = "eDP-1", mode = "1920x1200@60", position = "0x0", scale = 1.25 })
-- <<< omarchy-monitor-arranger <<<
BLOCK
}

# --- appends to a file that has no block yet, preserving user content
printf 'local scale = 1.25\nhl.env("GDK_SCALE", "1")\n' >"$OMARCHY_MONITORS_LUA"
check "append returns ok" "ok" "$(block first | "$BIN" save)"
ok "user content preserved" grep -q 'hl.env("GDK_SCALE", "1")' "$OMARCHY_MONITORS_LUA"
ok "block appended" grep -q 'position = "0x0"' "$OMARCHY_MONITORS_LUA"

# The block must land after the user's rules: Hyprland applies monitor rules in
# file order, so an earlier wildcard rule would otherwise win.
user_line=$(grep -n 'hl.env' "$OMARCHY_MONITORS_LUA" | cut -d: -f1)
block_line=$(grep -n 'omarchy-monitor-arranger >>>' "$OMARCHY_MONITORS_LUA" | cut -d: -f1)
ok "block sits after user content" [ "$block_line" -gt "$user_line" ]

# --- re-saving replaces the block instead of stacking another
block second >/dev/null
check "second save returns ok" "ok" "$(block second | "$BIN" save)"
check "still exactly one block" "1" "$(grep -c 'omarchy-monitor-arranger >>>' "$OMARCHY_MONITORS_LUA")"
check "still exactly one end marker" "1" "$(grep -c 'omarchy-monitor-arranger <<<' "$OMARCHY_MONITORS_LUA")"
ok "block content updated" grep -q 'Generated second' "$OMARCHY_MONITORS_LUA"
ok "user content survives re-save" grep -q 'hl.env("GDK_SCALE", "1")' "$OMARCHY_MONITORS_LUA"

# --- the regression this file exists for: an edit made to the config after the
# widget loaded must survive the next save. The helper re-reads at write time.
printf '\n-- edited by hand after the shell started\n' >>"$OMARCHY_MONITORS_LUA"
block third | "$BIN" save >/dev/null
ok "external edit survives a later save" grep -q 'edited by hand after the shell started' "$OMARCHY_MONITORS_LUA"

# --- refuses input that would destroy the config
check "empty input rejected" "1" "$(echo "" | "$BIN" save >/dev/null 2>&1; echo $?)"
check "input without hl.monitor rejected" "1" "$(echo "rm -rf /" | "$BIN" save >/dev/null 2>&1; echo $?)"
check "input without markers rejected" "1" \
  "$(echo 'hl.monitor({ output = "eDP-1" })' | "$BIN" save >/dev/null 2>&1; echo $?)"
ok "config intact after rejected writes" grep -q 'hl.env("GDK_SCALE", "1")' "$OMARCHY_MONITORS_LUA"

# --- malformed markers must not consume unrelated config on Save
cp "$OMARCHY_MONITORS_LUA" "$WORK/good.lua"
for malformed in missing-end stray-end reversed duplicate nested; do
  case "$malformed" in
    missing-end) printf '%s\n' '-- >>> omarchy-monitor-arranger >>>' 'hl.monitor({})' 'user_setting = true' ;;
    stray-end) printf '%s\n' 'user_setting = true' '-- <<< omarchy-monitor-arranger <<<' ;;
    reversed) printf '%s\n' '-- <<< omarchy-monitor-arranger <<<' '-- >>> omarchy-monitor-arranger >>>' 'hl.monitor({})' ;;
    duplicate) block one; block two ;;
    nested) printf '%s\n' '-- >>> omarchy-monitor-arranger >>>'; block nested ;;
  esac >"$WORK/malformed.lua"
  cp "$WORK/malformed.lua" "$OMARCHY_MONITORS_LUA"
  check "$malformed existing markers rejected" "1" "$(block fresh | "$BIN" save >/dev/null 2>&1; echo $?)"
  ok "$malformed existing config unchanged" cmp -s "$WORK/malformed.lua" "$OMARCHY_MONITORS_LUA"
  cp "$WORK/good.lua" "$OMARCHY_MONITORS_LUA"
  check "$malformed input markers rejected" "1" "$("$BIN" save <"$WORK/malformed.lua" >/dev/null 2>&1; echo $?)"
  ok "$malformed input leaves config unchanged" cmp -s "$WORK/good.lua" "$OMARCHY_MONITORS_LUA"
done

# --- clock collisions cannot overwrite a backup; backups stay private
mkdir "$WORK/collision-backups"
printf '#!/bin/bash\nprintf "20260913-120000\\n"\n' >"$WORK/stub/date"
chmod +x "$WORK/stub/date"
for i in 1 2 3; do
  block "collision$i" | OMARCHY_ARRANGER_BACKUPS="$WORK/collision-backups" "$BIN" save >/dev/null
done
check "same timestamp keeps distinct backups" "3" "$(ls -1 "$WORK/collision-backups" | wc -l | tr -d ' ')"
ok "backups private" test -z "$(find "$WORK/collision-backups" -type f -perm -004 -print)"
rm "$WORK/stub/date"

# --- backups accumulate but stay bounded
ok "backups written" [ "$(ls -1 "$OMARCHY_ARRANGER_BACKUPS" | wc -l)" -ge 2 ]
for i in $(seq 1 12); do block "bulk$i" | "$BIN" save >/dev/null; sleep 0.01; done
ok "backups capped at 10" [ "$(ls -1 "$OMARCHY_ARRANGER_BACKUPS" | wc -l)" -le 10 ]

# --- works when monitors.lua does not exist at all
rm -f "$OMARCHY_MONITORS_LUA"
check "creates a missing config" "ok" "$(block fresh | "$BIN" save)"
ok "fresh file has the block" grep -q 'omarchy-monitor-arranger >>>' "$OMARCHY_MONITORS_LUA"

if (( failures > 0 )); then
  echo
  echo "$failures test(s) failed"
  exit 1
fi
echo "all splice tests passed"
