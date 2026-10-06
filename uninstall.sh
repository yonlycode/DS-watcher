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
# `|| confirm=""` est indispensable sous `set -e` : un `read` qui bute sur EOF
# (exécution non interactive — cron, CI sans tty, `curl | bash`) retourne 1 et
# tuait le script AVANT la fin de la désinstallation, laissant unités systemd et
# fichiers à moitié retirés. Sur EOF on prend la réponse par défaut : on ne
# supprime rien.
confirm=""
read -rp "Voulez-vous aussi supprimer /etc/autodeploy (y/N) ? " confirm || confirm=""
if [[ "$confirm" =~ ^[yYoO]$ ]]; then
  rm -rf /etc/autodeploy
  echo "    [OK] /etc/autodeploy supprimé."
else
  echo "    [INFO] /etc/autodeploy conservé."
fi

echo "==> Suppression de l'état persistant..."
# L'état (dernier tag/digest déployés, compteurs d'échec) est séparé de la conf :
# le perdre ferait perdre la mémoire des tags cassés, donc le droit de les
# redéployer en boucle au premier cycle.
state_confirm=""
read -rp "Supprimer /var/lib/autodeploy (tags déployés, compteurs d'échec) ? (y/N) " state_confirm || state_confirm=""
if [[ "$state_confirm" =~ ^[yYoO]$ ]]; then
  rm -rf /var/lib/autodeploy
  echo "    [OK] /var/lib/autodeploy supprimé."
else
  echo "    [INFO] /var/lib/autodeploy conservé."
fi

# Le verrou vit en /run (tmpfs, purgé au reboot) : nettoyé ici par propreté.
rm -rf /run/autodeploy 2>/dev/null || true

echo "==> Désinstallation terminée."
