# Guide de Passage en Production : Checklist & Prérequis (Avec Registre Interne JFrog)

Ce document récapitule la frontière entre l'environnement de test local et la production, et détaille **tout ce qu'il reste à configurer ou valider pour déployer ce projet sur votre infrastructure réelle** (GitLab CI auto-hébergé + Registre Docker JFrog Artifactory interne + Traefik).

---

## 🧭 1. Architecture Cible en Production

```
+-------------------------------------------------------------------------------------------------+
|                                     INFRASTRUCTURE ENTREPRISE                                   |
|                                                                                                 |
|   +-----------------------+     git tag v1.2.0     +----------------------------------------+   |
|   |  GitLab Auto-hébergé  | ---------------------> |               GitLab CI                |   |
|   |                       |                        |  - docker build                        |   |
|   +-----------------------+                        |  - docker push vers JFrog Artifactory  |   |
|                                                    +-------------------+--------------------+   |
|                                                                        |                        |
|                                                                        v                        |
|                                                    +----------------------------------------+   |
|                                                    |     JFrog Artifactory (Docker Repo)    |   |
|                                                    |      jfrog.mon-entreprise.fr           |   |
|                                                    +-------------------+--------------------+   |
|                                                                        |                        |
|                                                                        v pull                   |
|   +--------------------------------------------------------------------+--------------------+   |
|   | SERVEUR DE PRODUCTION                                                                   |   |
|   |                                                                                         |   |
|   |   +---------------------------------------+    surveillance     +-------------------+   |
|   |   |        Moteur DS-Watcher              | <================== |  Systemd Timer    |   |
|   |   |   - Interroge les tags JFrog          |    toutes les 2 min |  autodeploy.timer |   |
|   |   |   - Pull image si nouvelle version    |                     +-------------------+   |
|   |   |   - Rolling update 0-downtime         |                                             |   |
|   |   +-------------------+-------------------+                                             |   |
|   |                       |                                                                 |   |
|   |                       v swap dynamique                                                  |   |
|   |   +-------------------+-------------------+       routage       +-------------------+   |
|   |   |          Conteneurs Docker            | <================== |      Traefik      |   |
|   |   |   (Réseau interne : traefik-net)      |       HTTP/HTTPS    |  (Existant prod)  |   |
|   |   +---------------------------------------+                     +-------------------+   |
+---+-----------------------------------------------------------------------------------------+---+
```

---

## 📋 2. Checklist : Ce qu'il reste à faire pour la mise en prod

```
[ ] 1. Côté Registre JFrog Artifactory
    [ ] Créer un compte de service / robot dédié (ex: svc-autodeploy)
    [ ] Attribuer les droits "Read" sur le repository Docker dans JFrog
    [ ] Générer une API Key ou un Identity Token pour ce compte

[ ] 2. Côté GitLab CI (.gitlab-ci.yml)
    [ ] Vérifier que le pipeline push bien l'image sur JFrog avec le tag sémantique (vX.Y.Z)
    [ ] S'assurer que le tag Docker correspond exactement au tag Git de release

[ ] 3. Côté Applications Réelles
    [ ] Vérifier la présence d'une instruction HEALTHCHECK dans chaque Dockerfile
    [ ] Vérifier que la route GET /health renvoie bien HTTP 200 quand l'app est prête
    [ ] Prévoir la gestion des migrations de base de données (si applicable)

[ ] 4. Côté Serveur de Production
    [ ] Vérifier le réseau Docker partagé avec Traefik (ex: traefik-net)
    [ ] Cloner ce dépôt et exécuter : sudo ./install.sh
    [ ] Renseigner /etc/autodeploy/autodeploy.env (Host JFrog, user, token)
    [ ] Créer un fichier de conf par application dans /etc/autodeploy/apps.d/
    [ ] Démarrer et valider le timer Systemd

[ ] 5. Monitoring (Recommandé)
    [ ] Renseigner l'URL Webhook (Slack / Discord / Teams) pour les alertes
```

---

## 🔍 3. Détail des Actions Requises

### Action 1 : Configurer le compte technique sur JFrog Artifactory

Pour que le serveur de production puisse vérifier les nouveaux tags et télécharger les images :
1. Sur **JFrog Artifactory**, créez un compte technique (ex: `svc-prod-deployer`).
2. Donnez-lui le rôle **Read** sur le dépôt Docker concerné (ex: `docker-local` ou `docker-prod`).
3. Générez un **Identity Token** ou une **API Key** pour cet utilisateur.

---

### Action 2 : Pipeline GitLab CI (`.gitlab-ci.yml`)

Votre pipeline GitLab CI construit l'application et la publie directement sur JFrog lors de la création d'un tag de release :

```yaml
stages:
  - build-and-publish

publish-to-jfrog:
  stage: build-and-publish
  image: docker:24-cli
  services:
    - docker:24-dind
  rules:
    # Déclenché uniquement sur les tags de type v1.0.0 ou 1.0.0
    - if: $CI_COMMIT_TAG =~ /^v?[0-9]+\.[0-9]+\.[0-9]+/
  variables:
    JFROG_REGISTRY: "jfrog.mon-entreprise.fr"
    IMAGE_NAME: "$JFROG_REGISTRY/docker-local/mon-app"
  script:
    - echo "$JFROG_CI_PASSWORD" | docker login "$JFROG_REGISTRY" -u "$JFROG_CI_USER" --password-stdin
    - docker build -t "$IMAGE_NAME:$CI_COMMIT_TAG" .
    - docker push "$IMAGE_NAME:$CI_COMMIT_TAG"
```

---

### Action 3 : `HEALTHCHECK` Docker + Graceful Shutdown dans les Dockerfiles

Le `HEALTHCHECK` Docker sert au **script** (validation du candidat avant bascule).
**Rappel important :** ce n'est PAS lui qui protège Traefik — pour ça, il faut les
labels `traefik.http.services.*.healthcheck.*` (cf. Action 4B). Ajoutez dans le
`Dockerfile` de chaque application :

```dockerfile
# Exemple pour Node.js / Python / Go / PHP / Java :
HEALTHCHECK --interval=3s --timeout=2s --retries=3 --start-period=5s \
  CMD wget -q -O - http://localhost:8080/health || exit 1
```

**Graceful shutdown (exigence).** Lors de la bascule, l'ancien conteneur reçoit un
`SIGTERM` puis est forcé après le grace period (`docker stop -t 15` côté script).
L'application **doit** drainer ses connexions en cours au `SIGTERM` avant de sortir,
sinon des requêtes actives sont coupées net. Exemple canonique (Node, cf.
`env/sample-app/server.js`) :

```js
process.on('SIGTERM', () => {
  server.close(() => process.exit(0)); // draine les connexions puis sort
});
```

Gardez le grace period **cohérent** avec le `-t 15` du script : une app qui met plus
de 15 s à drainer sera tuée en plein vol.

---

### Action 4 : Installation & Configuration sur le Serveur Hôte

Connectez-vous en SSH sur votre serveur de production :

```bash
# 1. Cloner le repo
git clone git@github.com:yonlycode/DS-watcher.git /opt/ds-watcher
cd /opt/ds-watcher

# 2. Lancer l'installation
sudo ./install.sh
```

#### A. Renseigner les identifiants JFrog : `/etc/autodeploy/autodeploy.env`
```bash
# Nom d'hôte de votre JFrog Artifactory
REGISTRY_HOST="jfrog.mon-entreprise.fr"

# Utilisateur technique JFrog
REGISTRY_USER="svc-prod-deployer"

# API Key ou Identity Token JFrog
REGISTRY_TOKEN="AKCp8xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

# Webhook optionnel pour recevoir les alertes
WEBHOOK_URL="https://discord.com/api/webhooks/xxx/yyy"

# Nettoyage automatique du disque
AUTO_PRUNE_IMAGES="true"
```

#### B. Déclarer vos applications : `/etc/autodeploy/apps.d/<mon-app>.conf`
Pour chaque application, créez un fichier `.conf` :

```bash
APP_NAME="mon-api"

# Chemin complet de l'image sur votre JFrog (SANS le tag)
IMAGE_REPO="jfrog.mon-entreprise.fr/docker-local/mon-api"

# Timeout de démarrage (secondes)
HEALTHCHECK_TIMEOUT=45

DOCKER_RUN_ARGS=(
  --restart unless-stopped
  --network "traefik-net" # Réseau partagé avec votre Traefik existant
  -e "NODE_ENV=production"
  -v "/var/data/mon-api:/app/data"

  # Labels Traefik de votre application
  --label "traefik.enable=true"
  --label "traefik.http.routers.mon-api.rule=Host(\`api.mon-entreprise.fr\`)"
  --label "traefik.http.routers.mon-api.entrypoints=websecure"
  --label "traefik.http.services.mon-api.loadbalancer.server.port=3000"

  # Healthcheck TRAEFIK (le vrai garde-fou : Traefik évince le candidat non prêt)
  --label "traefik.http.services.mon-api.loadbalancer.healthcheck.path=/health"
  --label "traefik.http.services.mon-api.loadbalancer.healthcheck.interval=3s"
  --label "traefik.http.services.mon-api.loadbalancer.healthcheck.timeout=2s"
)
```

> **Note :** Pas besoin de `GITLAB_PROJECT_ID` ici ! Le script interroge directement l'API Docker v2 de JFrog (`/v2/<repo>/tags/list`) pour trouver le dernier tag sémantique.

---

### Action 5 : Gestion des Migrations de Base de Données (Optionnel)

Si votre application nécessite des migrations de base de données à chaque release, vous pouvez utiliser le hook `PRE_DEPLOY_CMD` dans le fichier `.conf` :

```bash
PRE_DEPLOY_CMD="docker run --rm --network traefik-net -e DB_URL=\$DATABASE_URL \${IMAGE_REPO}:\${latest_tag} npm run migrate"
```

Si la migration échoue, le déploiement s'arrête immédiatement et l'ancien conteneur continue de tourner sans interruption.

---

## 🛡️ 5. Commandes d'Exploitation en Production

```bash
# 1. Tester manuellement la détection et le déploiement
sudo /usr/local/bin/autodeploy.sh

# 2. Vérifier que le timer Systemd est bien actif
systemctl list-timers autodeploy.timer

# 3. Suivre les logs en temps réel
journalctl -u autodeploy.service -f
```
