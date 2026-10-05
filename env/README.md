# Environnement de Test Local (OpenTofu / Terraform + Sample App)

Ce dossier contient une infrastructure de test locale complète permettant de reproduire fidèlement l'environnement de production sur votre machine de développement :
* **Un Docker Registry local** (`localhost:5001`) pour tester la publication d'images privées sans impacter votre GitLab d'entreprise.
* **Une instance Traefik v3** (`http://localhost:8080`) pour valider la découverte dynamique de conteneurs et le zéro-downtime.
* **Une application modèle (`sample-app`)** en Node.js avec un `Dockerfile` et un script de publication (`build-and-push.sh`) intégrant un endpoint `/health` simulable (bon ou défaillant).

---

## 🚀 Lancement rapide (Tout-en-un)

Un script automatise l'ensemble du cycle de vie (provisioning IaC, build v1.0.0, déploiement, mise à jour v1.1.0 avec test de trafic sans coupure, puis tentative v1.2.0 cassée avec validation du rollback) :

```bash
./env/test-full-scenario.sh
```

Ce script détecte automatiquement **OpenTofu** (`tofu`) ou **Terraform** (`terraform`).

---

## 🛠️ Utilisation Manuelle pas-à-pas

### 1. Démarrer l'infrastructure avec OpenTofu ou Terraform

```bash
cd env/terraform

# Initialisation du provider Docker
tofu init    # ou terraform init

# Déploiement du Registry (port 5001) et de Traefik (port 8080)
tofu apply -auto-approve
```

Vous avez alors :
* Le registre Docker privé sur `localhost:5001`
* Traefik HTTP sur `http://localhost:8080`
* Le Dashboard Traefik sur `http://localhost:8081`

---

### 2. Construire et publier des versions de l'application test

Dans `env/sample-app` :

```bash
cd ../sample-app

# Publier la version 1.0.0
./build-and-push.sh 1.0.0

# Publier une mise à jour 1.1.0
./build-and-push.sh 1.1.0

# Publier une version 1.2.0 cassée (simule un bug en prod où /health renvoie 500)
./build-and-push.sh 1.2.0 --broken
```

---

### 3. Tester le déploiement avec le script principal

Créez un fichier de conf de test ou exécutez `autodeploy.sh` en lui passant le dossier de configuration :

```bash
# Tester le déploiement
AUTODEPLOY_CONFIG_DIR=env/sandbox/config ./bin/autodeploy.sh
```

---

### 4. Détruire l'infrastructure de test

Quand vos tests sont terminés :

```bash
cd env/terraform
tofu destroy -auto-approve    # ou terraform destroy
```
