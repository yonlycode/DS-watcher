# Docker Autodeploy : POC de Rolling Update Zéro-Downtime avec Traefik & Systemd

Ce projet est un prototype d'automatisation de mise en production continue (Continuous Deployment) pour des environnements Docker standalone, basé sur **GitLab CI**, **Docker Registry**, **Traefik** et **Systemd**.

Il remplace les interventions manuelles en automatisant la surveillance des tags d'images Docker, le déploiement progressif sans coupure de service et le rollback automatique en cas de défaillance.

---

## 📑 Sommaire
1. [Principe de fonctionnement](#1-principe-de-fonctionnement)
2. [Pourquoi cette architecture garantit le Zéro-Downtime](#2-pourquoi-cette-architecture-garantit-le-zéro-downtime)
3. [Structure du projet](#3-structure-du-projet)
4. [Environnement de Test Local (OpenTofu / Terraform + Sample App)](#4-environnement-de-test-local-opentofu--terraform--sample-app)
5. [Documentation du Workflow Testé E2E (Détails complets)](docs/WORKFLOW_E2E.md)
6. [Guide de Passage en Production (Checklist & Prérequis)](docs/PASSAGE_EN_PROD.md)
7. [Prérequis Serveur](#5-prérequis)
8. [Guide d'installation](#6-guide-dinstallation)
9. [Configuration détaillée](#7-configuration-détaillée)
10. [Exploitation & Commandes usuelles](#8-exploitation--commandes-usuelles)
11. [Gestion des erreurs et Rollback](#9-gestion-des-erreurs-et-rollback)

---

## 1. Principe de fonctionnement


Le déploiement fonctionne selon une boucle périodique cadencée par **Systemd Timer** (toutes les 2 minutes par défaut) :

```mermaid
flowchart TD
    A["Systemd Timer (autodeploy.timer)"] -->|"Déclenche toutes les 2 min"| B["autodeploy.sh"]
    B --> C["Vérification du Lock (/var/run/autodeploy.lock)"]
    C --> D["docker login sur le registre GitLab"]
    D --> E["Pour chaque app dans /etc/autodeploy/apps.d/*.conf"]
    
    E --> F["Interrogation API GitLab : GET /tags"]
    F --> G["Extraction du dernier tag sémantique (sort -V)"]
    
    G --> H{"Image actuelle == Nouveau tag ?"}
    H -->|"Oui"| I["Rien à faire (application à jour)"]
    H -->|"Non"| J["docker pull de la nouvelle image"]
    
    J --> K["docker run app-candidate en parallèle (sur traefik-net)"]
    K --> L{"Surveillance Healthcheck (boucle 45s)"}
    
    L -->|"Healthy"| M["Bascule Traefik (sleep 2s)"]
    M --> N["docker stop & docker rm ancien conteneur"]
    N --> O["docker rename app-candidate -> app"]
    O --> P["Notification succès (Webhook optionnel)"]
    
    L -->|"Unhealthy / Crash"| Q["ROLLBACK AUTOMATIQUE"]
    Q --> R["docker stop & docker rm app-candidate"]
    R --> S["Ancien conteneur préservé à 100%"]
    S --> T["Notification alerte (Webhook optionnel)"]
```

---

## 2. Pourquoi cette architecture garantit le Zéro-Downtime

Avec Docker classique sans orchestrateur (ni Swarm ni Kubernetes), deux conteneurs ne peuvent pas écouter sur le même port de la machine hôte (`-p 80:80`).

**La solution avec Traefik :**
1. Les conteneurs ne publient **aucun port sur l'hôte**. Ils communiquent uniquement via un réseau Docker interne partagé avec Traefik (`traefik-net`).
2. Le nouveau conteneur candidat (`myapp-candidate`) démarre avec **les mêmes labels Traefik** que le conteneur en production (`traefik.http.routers.myapp...` et `traefik.http.services.myapp...`).
3. Tant que le conteneur candidat n'a pas validé son `HEALTHCHECK`, Traefik ne lui envoie **aucune** requête HTTP.
4. Dès qu'il devient `healthy`, Traefik commence à répartir le trafic sur les deux conteneurs.
5. Lorsque l'ancien conteneur est stoppé (`docker stop`), Traefik le retire instantanément de ses routes actives.
6. Résultat : **zéro paquet perdu**, transition 100% fluide pour les utilisateurs.

---

## 3. Structure du projet

```
.
├── bin/
│   └── autodeploy.sh               # Moteur bash principal (rolling deploy + healthcheck + rollback)
├── config/
│   ├── autodeploy.env.example      # Template de variables globales (GitLab, tokens)
│   └── apps.d/
│       └── example-app.conf.example # Modèle de configuration par conteneur
├── systemd/
│   ├── autodeploy.service          # Définition de l'unité Systemd
│   └── autodeploy.timer            # Définition du timer périodique
├── env/                            # Environnement de test local complet
│   ├── terraform/                  # Code IaC OpenTofu / Terraform (Registry v2 + Traefik v3)
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── versions.tf
│   │   └── outputs.tf
│   ├── sample-app/                 # Application de démonstration avec Healthcheck
│   │   ├── server.js
│   │   ├── Dockerfile
│   │   └── build-and-push.sh       # Script de build et push (versions saines et cassées)
│   ├── test-full-scenario.sh       # Scénario de test automatisé end-to-end
│   └── README.md
├── demo/
│   └── test-local-simulation.sh    # Simulation autonome sans IaC
├── install.sh                      # Script d'installation automatique
├── uninstall.sh                    # Script de désinstallation propre
└── README.md
```

---

## 4. Environnement de Test Local (OpenTofu / Terraform + Sample App)

Pour tester le flux complet de bout en bout sur votre machine avec **OpenTofu** ou **Terraform** :

```bash
# Lancement du scénario complet automatisé
./env/test-full-scenario.sh
```

Ce scénario automatique va :
1. Déployer avec `tofu` (ou `terraform`) un Docker Registry local (`localhost:5001`) et Traefik (`localhost:8080`).
2. Construire et publier l'image `sample-app:1.0.0` sur le registre local.
3. Déclencher `autodeploy.sh` pour déployer la v1.0.0.
4. Construire et publier la mise à jour `sample-app:1.1.0`.
5. Exécuter un trafic HTTP continu et déclencher le rolling update sans aucune interruption (0 downtime).
6. Construire et publier une version `sample-app:1.2.0` avec un endpoint `/health` défaillant (erreur 500).
7. Valider que le script déclenche le **Rollback automatique**, détruit le candidat défaillant et maintient la version stable en production.


---

## 5. Prérequis

Sur le serveur de production (Debian, Ubuntu, RHEL, Rocky Linux, etc.) :

1. **Docker Engine** installé et fonctionnel.
2. **Outils système requis** : `curl`, `jq`, `sort`, `grep` (présents par défaut ou via `apt install curl jq`).
3. **Un jeton GitLab** (uniquement en prod avec GitLab privé) :
   * Recommandé : Un **Deploy Token** de projet ou de groupe GitLab avec les scopes :
     * `read_repository`
     * `read_registry`
   * Ou un **Personal Access Token (PAT)** avec le scope `read_api`.

---

## 6. Guide d'installation

### Étape 1 : Cloner le dépôt et lancer l'installateur
Sur le serveur hôte :
```bash
git clone <url_de_votre_repo> autodeploy
cd autodeploy
sudo ./install.sh
```

L'installateur :
* Installe `/usr/local/bin/autodeploy.sh` (permissions 755).
* Crée `/etc/autodeploy/` et `/etc/autodeploy/apps.d/`.
* Copie le template d'environnement dans `/etc/autodeploy/autodeploy.env` (permissions 600).
* Installe et démarre le timer Systemd.

---

## 7. Configuration détaillée


### 1. Variables globales : `/etc/autodeploy/autodeploy.env`

Éditez le fichier `/etc/autodeploy/autodeploy.env` :
```bash
# URL de votre GitLab interne
GITLAB_URL="https://gitlab.mon-entreprise.com"

# Nom d'hôte du Registry Docker GitLab (port inclus si nécessaire)
GITLAB_REGISTRY="registry.gitlab.mon-entreprise.com"

# Nom d'utilisateur pour docker login (ex: deploy-token-prod)
GITLAB_USER="deploy-token-prod"

# Token secret (Deploy Token ou PAT)
GITLAB_TOKEN="glpat-xxxxxxxxxxxxxxxxxxxx"

# Optionnel : Webhook pour recevoir les alertes sur Slack/Discord/Teams
WEBHOOK_URL="https://discord.com/api/webhooks/xxx/yyy"

# Nettoyage automatique des images orphelines (évite de saturer le disque)
AUTO_PRUNE_IMAGES="true"
```

### 2. Déclaration d'une application : `/etc/autodeploy/apps.d/<nom>.conf`

Pour chaque conteneur à surveiller, créez un fichier `.conf` distinct dans `/etc/autodeploy/apps.d/` (ex: `/etc/autodeploy/apps.d/mon-api.conf`) :

```bash
# Nom du conteneur en production
APP_NAME="mon-api"

# URL de l'image (sans le tag)
IMAGE_REPO="registry.gitlab.mon-entreprise.com/pole-tech/mon-api"

# ID du projet GitLab (visible sur la page d'accueil du projet sous le titre)
GITLAB_PROJECT_ID="142"

# Réseau Docker partagé avec Traefik
DOCKER_NETWORK="traefik-net"

# Timeout de validation de démarrage (secondes)
HEALTHCHECK_TIMEOUT=45

# Paramètres du 'docker run'
# NOTE : N'incluez ni le nom (--name) ni l'image, le script s'en charge.
DOCKER_RUN_ARGS=(
  --restart unless-stopped
  --network "$DOCKER_NETWORK"
  
  # Variables d'environnement applicatives
  -e "NODE_ENV=production"
  -e "PORT=3000"

  # Labels Traefik pour le routage dynamique
  --label "traefik.enable=true"
  --label "traefik.http.routers.mon-api.rule=Host(\`api.mon-entreprise.com\`)"
  --label "traefik.http.routers.mon-api.entrypoints=websecure"
  --label "traefik.http.routers.mon-api.tls=true"
  --label "traefik.http.services.mon-api.loadbalancer.server.port=3000"

  # Healthcheck Docker (indispensable pour que le script sache si l'app est prête)
  --health-cmd "curl -f http://localhost:3000/health || exit 1"
  --health-interval 3s
  --health-timeout 2s
  --health-retries 3
  --health-start-period 5s
)
```

---

## 7. Tester le POC localement (Simulation interactive)

Un script de démo est fourni dans `demo/test-local-simulation.sh`. Il ne nécessite aucun GitLab externe et permet de valider le comportement en conditions réelles sur votre poste avec Docker.

Ce script :
1. Démarre une instance locale de **Traefik**.
2. Construit localement 3 images de test :
   * `v1.0.0` (production initiale)
   * `v1.1.0` (mise à jour)
   * `v1.2.0` (version défaillante avec un `/health` cassé)
3. Lance un bombardement de requêtes HTTP en tâche de fond.
4. Effectue le rolling update vers `v1.1.0` et **prouve qu'aucune requête n'échoue** (zéro downtime).
5. Tente de déployer la version `v1.2.0` cassée : **déclenche le rollback automatique** et prouve que la `v1.1.0` est restée active sans interruption.

Pour exécuter la démo :
```bash
./demo/test-local-simulation.sh
```

---

## 8. Exploitation & Commandes usuelles

### Suivre l'activité en temps réel
Pour consulter les logs du service :
```bash
journalctl -u autodeploy.service -f
```

### Vérifier le prochain passage du Timer
```bash
systemctl list-timers autodeploy.timer
```

### Forcer un déploiement immédiat (sans attendre le timer)
```bash
sudo systemctl start autodeploy.service
```

### Exécuter le script manuellement pour déboguer
```bash
sudo /usr/local/bin/autodeploy.sh
```

---

## 9. Gestion des erreurs et Rollback

Le script implémente plusieurs mécanismes de robustesse :

| Scénario d'erreur | Action prise par le script | Impact en production |
|---|---|---|
| **Réseau / Registre indisponible** | `docker pull` échoue, abandon du cycle. | **Aucun** (l'ancien conteneur continue). |
| **Crash au démarrage du conteneur** | Statut `exited` détecté immédiatement. Suppression du candidat. | **Aucun** (l'ancien conteneur continue). |
| **Erreur applicative (Healthcheck KO)** | Timeout atteint sans statut `healthy`. Logs d'erreur affichés. Suppression du candidat. | **Aucun** (l'ancien conteneur continue). |
| **Deux timers se chevauchent** | Verrou `flock` sur `/var/run/autodeploy.lock`. La 2ème instance sort proprement. | **Aucun** (pas de concurrence). |
| **Disque saturé d'images** | `docker image prune -f` exécuté automatiquement à la fin de chaque passage. | Disque nettoyé des versions obsolètes. |
