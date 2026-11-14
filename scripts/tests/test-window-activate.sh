#!/usr/bin/env bash
# Exercise existing-window activation with prebuilt binaries on a private X11 display.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
"$ROOT_DIR/scripts/check-ghostty.sh"
for dependency in xvfb-run xdotool metacity dbus-run-session jq setsid timeout; do
  command -v "$dependency" >/dev/null || { echo "Missing dependency: $dependency"; exit 2; }
done
if [ "${1:-}" != --inside ]; then
  LIMUX_ACTIVATE_TEST_DIR="$(mktemp -d -t limux-window-activate-XXXXXX)"
  export LIMUX_ACTIVATE_TEST_DIR
  export XDG_DATA_HOME="$LIMUX_ACTIVATE_TEST_DIR/data" XDG_STATE_HOME="$LIMUX_ACTIVATE_TEST_DIR/state"
  export XDG_CONFIG_HOME="$LIMUX_ACTIVATE_TEST_DIR/config" XDG_RUNTIME_DIR="$LIMUX_ACTIVATE_TEST_DIR/runtime"
  export XDG_CACHE_HOME="$LIMUX_ACTIVATE_TEST_DIR/cache"
  mkdir -p "$XDG_DATA_HOME/limux" "$XDG_STATE_HOME" "$XDG_CONFIG_HOME/ghostty" "$XDG_RUNTIME_DIR" "$XDG_CACHE_HOME"
  chmod 700 "$XDG_RUNTIME_DIR"
  export GTK_USE_PORTAL=0 GTK_A11Y=none GIO_USE_VFS=local GSETTINGS_BACKEND=memory
  unset DBUS_SESSION_BUS_ADDRESS DBUS_STARTER_ADDRESS DBUS_STARTER_BUS_TYPE DISPLAY WAYLAND_DISPLAY
  unset GNOME_KEYRING_CONTROL SSH_AUTH_SOCK GPG_AGENT_INFO
  # This test needs a private bus, not desktop service activation.
  cat >"$LIMUX_ACTIVATE_TEST_DIR/dbus.conf" <<'DBUS'
<busconfig>
  <type>session</type>
  <listen>unix:tmpdir=/tmp</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
DBUS
  exec xvfb-run -a -s '-screen 0 1440x1000x24 -nolisten tcp' \
    dbus-run-session --config-file="$LIMUX_ACTIVATE_TEST_DIR/dbus.conf" -- bash "$0" --inside
fi

HOST="${LIMUX_TEST_HOST:-$ROOT_DIR/target/debug/limux}"
CLI="${LIMUX_TEST_CLI:-$ROOT_DIR/target/debug/limux-cli}"
if [ ! -x "$HOST" ] || [ ! -x "$CLI" ]; then echo "Build the host and CLI first"; exit 2; fi
RUN_DIR="${LIMUX_ACTIVATE_TEST_DIR:?}"
SOCKET="$RUN_DIR/limux.sock"
echo "Test artifacts: $RUN_DIR"
export LIMUX_SOCKET="$SOCKET" LIMUX_SOCKET_PATH="$SOCKET" LIMUX_SOCKET_MODE=localUser
export GDK_BACKEND=x11 GDK_SCALE=1 GTK_THEME=Adwaita
export LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe LP_NUM_THREADS=1 SHELL=/bin/sh ENV=/dev/null
export LD_LIBRARY_PATH="$ROOT_DIR/ghostty/zig-out/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export GHOSTTY_RESOURCES_DIR="$ROOT_DIR/ghostty/zig-out/share/ghostty"
export TERMINFO="$ROOT_DIR/ghostty/zig-out/share/terminfo"
unset LIMUX_WORKSPACE_ID LIMUX_PANE_ID LIMUX_SURFACE_ID LIMUX_TAB_ID LD_PRELOAD GDK_DPI_SCALE
unset XDG_ACTIVATION_TOKEN DESKTOP_STARTUP_ID
printf 'command = /bin/sh\nshell-integration = none\n' >"$XDG_CONFIG_HOME/ghostty/config"
jq -n --arg cwd "$RUN_DIR" '{version: 1, active_workspace_index: 1,
  workspaces: [range(1; 3) | . as $pane | {
    id: ("00000000-0000-4000-8000-00000000000" + tostring), name: ("Workspace " + tostring), cwd: $cwd,
    layout: {kind: "pane", pane_id: $pane, active_tab_id: ("second-" + tostring), tabs: [
      {id: ("first-" + tostring), tab_kind: "terminal", cwd: $cwd},
      {id: ("second-" + tostring), tab_kind: "terminal", cwd: $cwd}
    ]}
  }]
}' >"$XDG_DATA_HOME/limux/session.json"

HOST_PID=""
WM_PID=""
# shellcheck disable=SC2317 # Invoked by the EXIT trap.
cleanup() {
  local result=$? pid
  if [ "$result" -ne 0 ]; then tail -n 40 "$RUN_DIR/host.stderr" "$RUN_DIR/wm.stderr" || true; fi
  for pid in "$HOST_PID" "$WM_PID"; do
    [ -n "$pid" ] || continue
    kill -TERM -- "-$pid" 2>/dev/null || true
    for _ in $(seq 1 50); do
      if ! kill -0 "$pid" 2>/dev/null; then break; fi
      sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then kill -KILL -- "-$pid" 2>/dev/null || true; fi
    wait "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT
# A real window manager is needed to exercise minimize/present, not raw X unmapping.
setsid metacity --sm-disable --no-composite >"$RUN_DIR/wm.stdout" 2>"$RUN_DIR/wm.stderr" &
WM_PID=$!
for _ in $(seq 1 50); do
  kill -0 "$WM_PID" || { echo "Window manager exited during startup"; exit 1; }
  if xdotool get_desktop >/dev/null 2>&1; then break; fi
  sleep 0.1
done
xdotool get_desktop >/dev/null
setsid "$HOST" >"$RUN_DIR/host.stdout" 2>"$RUN_DIR/host.stderr" &
HOST_PID=$!
# Deliberately conflicting defaults prove that --socket selects the instance.
export LIMUX_SOCKET="$RUN_DIR/not-the-instance.sock" LIMUX_SOCKET_PATH="$RUN_DIR/also-absent.sock"
cli() { "$CLI" --socket "$SOCKET" --json --id-format both "$@"; }
WINDOW=""
for _ in $(seq 1 450); do
  kill -0 "$HOST_PID" || { echo "Host exited during startup"; exit 1; }
  WINDOW="$(xdotool search --all --onlyvisible --pid "$HOST_PID" --name '^Limux v' 2>/dev/null | head -1 || true)"
  if [ -n "$WINDOW" ] && cli identify >"$RUN_DIR/ready.json" 2>/dev/null \
    && jq -e '.focused.name == "Workspace 2" and .focused.surface_id == "2:second-2"' \
      "$RUN_DIR/ready.json" >/dev/null; then break; fi
  sleep 0.1
done
if [ -z "$WINDOW" ]; then echo "Host startup timed out"; exit 1; fi
jq -e '.focused.name == "Workspace 2" and .focused.surface_id == "2:second-2"' \
  "$RUN_DIR/ready.json" >/dev/null

snapshot() {
  cli list-workspaces | jq -Sc '[.workspaces[] | {workspace_id, selected}]'
  for workspace in 1 2; do
    cli list-panels --workspace "00000000-0000-4000-8000-00000000000$workspace" \
      | jq -Sc '[.surfaces[] | {surface_id, selected}]'
  done
  cli identify | jq -Sc '.focused | {workspace_id, pane_id, surface_id}'
}
windows() { xdotool search --name '^Limux v' | sort -n; }
snapshot >"$RUN_DIR/before.json"
windows >"$RUN_DIR/before.windows"
[ "$(wc -l <"$RUN_DIR/before.windows")" -eq 1 ]
timeout 5s xdotool windowminimize --sync "$WINDOW"
if xdotool search --onlyvisible --name '^Limux v' | grep -Fx "$WINDOW" >/dev/null; then
  echo 'FAIL: test window was not minimized'
  exit 1
fi
cli activate | jq -e '.presented == true' >/dev/null
for _ in $(seq 1 50); do
  if xdotool search --onlyvisible --name '^Limux v' | grep -Fx "$WINDOW" >/dev/null; then break; fi
  sleep 0.1
done
xdotool search --onlyvisible --name '^Limux v' | grep -Fx "$WINDOW" >/dev/null
[ "$("$CLI" --socket "$SOCKET" activate)" = OK ]
snapshot >"$RUN_DIR/after.json"
diff -u "$RUN_DIR/before.json" "$RUN_DIR/after.json"
echo 'PASS: explicit socket presents the same window and preserves workspace/tab selection'

if "$CLI" --socket "$RUN_DIR/missing.sock" activate >"$RUN_DIR/missing.stdout" 2>"$RUN_DIR/missing.stderr"; then
  echo 'FAIL: activation succeeded without a listening instance'
  exit 1
fi
grep -F "failed to connect to socket $RUN_DIR/missing.sock" "$RUN_DIR/missing.stderr"
kill -0 "$HOST_PID"
windows >"$RUN_DIR/after.windows"
diff -u "$RUN_DIR/before.windows" "$RUN_DIR/after.windows"
echo 'PASS: activation never creates a window or launches a missing instance'
