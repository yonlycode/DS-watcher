#!/usr/bin/env bash
# ==============================================================================
# Script d'installation d'Autodeploy
# ==============================================================================
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] Ce script d'installation doit être exécuté en tant que root (sudo ./install.sh)" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Installation des dépendances système..."
for pkg in curl jq docker; do
  if ! command -v "$pkg" &>/dev/null; then
    echo "[WARN] La commande '$pkg' n'a pas été trouvée sur votre système."
  fi
done

echo "==> Création des répertoires de configuration..."
mkdir -p /etc/autodeploy/apps.d
chmod 750 /etc/autodeploy

# État persistant par app (tags déployés, digest de référence, compteurs d'échec).
# 700 : l'état expose la liste des apps et leurs versions, et un fichier d'état
# corrompu/édité à la main peut faire redéployer ou sauter la mauvaise version.
echo "==> Création du répertoire d'état persistant..."
mkdir -p /var/lib/autodeploy
chmod 700 /var/lib/autodeploy
echo "    [OK] /var/lib/autodeploy (état par app : last_deployed_tag/digest, échecs)."

# Répertoire du verrou d'exécution. Recréé aussi par systemd (RuntimeDirectory=)
# et auto-créé par le script : les trois chemins convergent vers /run/autodeploy.
# JAMAIS /tmp : systemd-tmpfiles peut y supprimer un lock encore actif.
echo "==> Création du répertoire de verrou..."
mkdir -p /run/autodeploy
chmod 700 /run/autodeploy
echo "    [OK] /run/autodeploy (verrou d'exécution, root-only)."

echo "==> Installation du script exécutable..."
cp "${SCRIPT_DIR}/bin/autodeploy.sh" /usr/local/bin/autodeploy.sh
chmod 755 /usr/local/bin/autodeploy.sh

echo "==> Mise en place des fichiers de configuration..."
if [[ ! -f /etc/autodeploy/autodeploy.env ]]; then
  cp "${SCRIPT_DIR}/config/autodeploy.env.example" /etc/autodeploy/autodeploy.env
  chmod 600 /etc/autodeploy/autodeploy.env
  echo "    [NOTE] Fichier /etc/autodeploy/autodeploy.env créé (à renseigner avec vos identifiants)."
else
  echo "    [OK] Fichier /etc/autodeploy/autodeploy.env existant conservé."
fi

if [[ ! -f /etc/autodeploy/apps.d/example-app.conf.example ]]; then
  cp "${SCRIPT_DIR}/config/apps.d/example-app.conf.example" /etc/autodeploy/apps.d/example-app.conf.example
fi

echo "==> Installation des unités Systemd..."
if command -v systemctl &>/dev/null; then
  cp "${SCRIPT_DIR}/systemd/autodeploy.service" /etc/systemd/system/autodeploy.service
  cp "${SCRIPT_DIR}/systemd/autodeploy.timer" /etc/systemd/system/autodeploy.timer

  systemctl daemon-reload
  systemctl enable --now autodeploy.timer
  echo "    [OK] Service et Timer Systemd activés !"
  systemctl list-timers autodeploy.timer
else
  echo "[WARN] systemctl non détecté (environnement sans systemd ?). Veuillez gérer le lancement manuellement."
fi

echo ""
echo "=============================================================================="
echo " Installation terminée avec succès !"
echo " Prochaines étapes :"
echo "   1. Éditez /etc/autodeploy/autodeploy.env avec vos tokens GitLab."
echo "   2. Créez vos fichiers applicatifs dans /etc/autodeploy/apps.d/*.conf"
echo "   3. Surveillez les logs avec : journalctl -u autodeploy.service -f"
echo "=============================================================================="
