#!/bin/bash
# ── Shared helpers ────────────────────────────────────────────────
# Sourced by homelab.sh — do not execute directly.
[[ -n "${SCRIPT_DIR:-}" ]] || { echo "Source via homelab.sh" >&2; exit 1; }

die()     { echo "✗ $*" >&2; exit 1; }
step()    { echo ""; echo "▶ $*"; }
info()    { echo "  $*"; }
confirm() { read -rp "  $* [y/N] " r; [[ "${r,,}" == "y" ]]; }

need() { command -v "$1" &>/dev/null || die "'$1' not found — $2"; }

env_set() {
  local key="$1" val="$2"
  if grep -q "^${key}=" "$ENV_FILE"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
  else
    echo "${key}=${val}" >> "$ENV_FILE"
  fi
}

rand32() { od -An -tu4 -N4 /dev/urandom | tr -d ' \n'; }

gen_h_values() {
  H1=$(rand32)
  H2=$(rand32); while [[ "$H2" == "$H1" ]]; do H2=$(rand32); done
  H3=$(rand32); while [[ "$H3" == "$H1" || "$H3" == "$H2" ]]; do H3=$(rand32); done
  H4=$(rand32); while [[ "$H4" == "$H1" || "$H4" == "$H2" || "$H4" == "$H3" ]]; do H4=$(rand32); done
  export H1 H2 H3 H4
}
