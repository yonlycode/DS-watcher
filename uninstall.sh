#!/usr/bin/env bash
# ==============================================================================
# Script de désinstallation d'Autodeploy
# ==============================================================================
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] Ce script doit être exécuté en tant que root (sudo ./uninstall.sh)" >&2
  exit 1
fi

echo "==> Arrêt et désactivation du timer Systemd..."
if command -v systemctl &>/dev/null; then
  systemctl stop autodeploy.timer 2>/dev/null || true
  systemctl disable autodeploy.timer 2>/dev/null || true
  rm -f /etc/systemd/system/autodeploy.service /etc/systemd/system/autodeploy.timer
  systemctl daemon-reload
fi

echo "==> Suppression du binaire..."
rm -f /usr/local/bin/autodeploy.sh

echo "==> Suppression des fichiers de configuration..."
read -rp "Voulez-vous aussi supprimer /etc/autodeploy (y/N) ? " confirm
if [[ "$confirm" =~ ^[yYoO]$ ]]; then
  rm -rf /etc/autodeploy
  echo "    [OK] /etc/autodeploy supprimé."
else
  echo "    [INFO] /etc/autodeploy conservé."
fi

echo "==> Désinstallation terminée."
