# Packaged by launcher.nix; HyprGlass renders the live backdrop in the compositor.
set -euo pipefail
runtime=${XDG_RUNTIME_DIR:?A Wayland session is required}
umask 077
exec 9>"$runtime/wofi-glass.lock"
flock -n 9 || exit 0
style="$WOFI_GLASS_ASSETS/style-fallback.css"
if hyprctl plugin list -j 2>/dev/null | jq -e 'any(.[]; .name == "hyprglass")' >/dev/null; then
    style="$WOFI_GLASS_ASSETS/style.css"
fi
args=(--conf "$WOFI_GLASS_ASSETS/config" --style "$style")
if monitor=$(hyprctl monitors -j | jq -er 'first(.[] | select(.focused and (.disabled | not))) | .name'); then
    args+=(--monitor "$monitor")
fi
launcher_pid=
# Invoked indirectly by the EXIT trap.
# shellcheck disable=SC2317
cleanup() {
    if [[ -n "$launcher_pid" ]]; then
        kill "$launcher_pid" 2>/dev/null || true
        wait "$launcher_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT
trap 'exit 0' INT TERM HUP
# Keep the lock in the parent so launched applications cannot inherit it.
wofi "${args[@]}" "$@" <&0 9>&- &
launcher_pid=$!
wait "$launcher_pid" || status=$?
launcher_pid=
exit "${status:-0}"
