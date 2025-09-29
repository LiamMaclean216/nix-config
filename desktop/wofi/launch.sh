#!/usr/bin/env bash

# Launch wofi and close it if it ever loses focus.
wofi --show drun -n &
wofi_pid=$!

cleanup() {
  kill "$wofi_pid" 2>/dev/null || true
}

trap cleanup EXIT

# Give Hyprland a moment to focus the window before monitoring.
sleep 0.1

# Kill wofi if its not focused./
while kill -0 "$wofi_pid" 2>/dev/null; do
  focused_class=$(hyprctl activewindow 2>/dev/null | awk -F': ' '/class:/ {print $2; exit}')
  focused_class=${focused_class,,}

  if [[ -n "$focused_class" && "$focused_class" != "wofi" ]]; then
    kill "$wofi_pid" 2>/dev/null || true
    break
  fi

  sleep 0.05
done

wait "$wofi_pid" 2>/dev/null || true
