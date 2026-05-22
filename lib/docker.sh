#!/bin/bash
# ── Docker wrapper (auto-detects if sudo is needed) ───────────────
# Sourced by homelab.sh — do not execute directly.
[[ -n "${SCRIPT_DIR:-}" ]] || { echo "Source via homelab.sh" >&2; exit 1; }

if docker info &>/dev/null 2>&1; then
  DOCKER="docker"
elif sudo docker info &>/dev/null 2>&1; then
  DOCKER="sudo docker"
else
  die "Docker not reachable. Install Docker or add user to docker group."
fi
