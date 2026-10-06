# Documentation du Workflow Complet Testé & Validé (End-to-End)

Ce document décrit en détail le cycle de vie complet validé sur l'environnement de test avec **OpenTofu**, le **Docker Registry local**, **Traefik v3** et le moteur **Autodeploy**.

---

## 🏗️ 1. Architecture du Banc de Test

```
+-----------------------------------------------------------------------------------------+
|                                      MACHINE HÔTE                                       |
|                                                                                         |
|   +-------------------+       +-----------------------+       +---------------------+   |
|   |  Docker Registry  |       |   Traefik Proxy v3    |       |  Systemd / Script   |   |
|   |  localhost:5001   |       |  http://localhost:9080|       |    autodeploy.sh    |   |
|   +---------^---------+       +-----------^-----------+       +----------+----------+   |
|             |                             |                              |              |
|             | push / pull                 | reverse-proxy dynamique      | inspect /    |
|             |                             | (découverte par labels)      | swap         |
|             |                             |                              |              |
|   +---------v-----------------------------v------------------------------v----------+   |
|   |                     Réseau Docker Bridge : autodeploy-test-net                  |   |
|   |                                                                                 |   |
|   |   [Conteneur Actuel (Stable)]              [Conteneur Candidat (En test)]       |   |
|   |   sample-app                               sample-app-candidate                 |   |
|   |   Image: localhost:5001/sample-app:1.1.0   Image: localhost:5001/sample-app:1.2.0|  |
|   |   Status: healthy (reçoit le trafic)       Status: starting -> healthcheck...   |   |
|   +---------------------------------------------------------------------------------+   |
+-----------------------------------------------------------------------------------------+
```

---

## 🔄 2. Déroulement Pas-à-Pas du Scénario Validé

Le test exécuté par `./env/test-full-scenario.sh` valide successivement quatre phases critiques.

### Phase 0 : Provisioning de l'Infrastructure avec OpenTofu
L'infrastructure requise est déclarée en IaC dans `env/terraform/` et déployée via OpenTofu :
* **Réseau Docker :** `autodeploy-test-net` (isole le trafic interne entre Traefik et les applications).
* **Registry Docker v2 :** Conteneur `test-registry` (`registry:2`) mappé sur le port `localhost:5001`.
* **Reverse Proxy Traefik v3 :** Conteneur `test-traefik` (`traefik:v3.0`) branché sur le socket Docker, écoutant sur le port `9080` (HTTP) et `9081` (Dashboard).

```bash
cd env/terraform
tofu init
tofu apply -auto-approve
```

---

### Phase 1 : Première Déploiement de l'Application (v1.0.0)

1. **Build et Publication :**
   ```bash
   ./env/sample-app/build-and-push.sh 1.0.0
   ```
   * Construit une image Node.js Alpine avec un `HEALTHCHECK` Docker natif (`wget -q -O - http://127.0.0.1:3000/health`).
   * Pousse l'image sur `localhost:5001/sample-app:1.0.0`.

2. **Exécution d'Autodeploy :**
   * Le script interroge l'API du registre (`/v2/sample-app/tags/list`).
   * Détecte le tag sémantique le plus récent : `1.0.0`.
   * Constate qu'aucun conteneur `sample-app` ne tourne.
   * Démarre le conteneur candidat `sample-app-candidate`.
   * Attend que son statut passe à `healthy` (vérification toutes les 2 secondes).
   * Dès confirmation de santé, renomme le conteneur en `sample-app`.
   * Traefik route immédiatement les requêtes vers ce conteneur.

3. **Vérification curl :**
   ```bash
   curl http://localhost:9080/
   # Réponse : [Sample App] Version: 1.0.0 | Host: e57d19dfb4a4 | Uptime: 4s
   ```

---

### Phase 2 : Rolling Update Zéro Downtime (v1.0.0 -> v1.1.0)

C'est l'étape la plus critique : mettre à jour le conteneur sans couper le service.

1. **Build et Publication de la mise à jour :**
   ```bash
   ./env/sample-app/build-and-push.sh 1.1.0
   ```

2. **Mesure continue de la disponibilité :**
   * Un client HTTP en tâche de fond envoie des requêtes en continu toutes les 200ms vers `http://localhost:9080/`.

3. **Déroulement de la bascule dans `autodeploy.sh` :**
   * Détection du nouveau tag `1.1.0` (différent de la version en cours `1.0.0`).
   * Téléchargement en tâche de fond : `docker pull localhost:5001/sample-app:1.1.0` *(l'ancien conteneur continue de servir le trafic)*.
   * Démarrage du conteneur candidat `sample-app-candidate` sur le même réseau et avec les **mêmes labels de service Traefik**.
   * Attente du `HEALTHCHECK` **côté script** : le `HEALTHCHECK` Docker sert à `autodeploy.sh` pour décider ou non de basculer.
     **Ce que ce document affirmait à tort ici :** le provider Docker de Traefik ne lit **pas** `.State.Health`. Il route vers le candidat dès qu'il voit les labels, prêt ou non. Ce qui protège réellement le trafic pendant cette phase, ce sont les labels `traefik.http.services.*.loadbalancer.healthcheck.*` (la sonde propre à Traefik), pas le `HEALTHCHECK` Docker. Voir README §2.
   * Dès que le statut devient `healthy` :
     * Le candidat est déjà dans le pool — à condition que ses labels de service soient **identiques** à ceux de l'ancien (condition dure, README §2 règle 1).
     * Arrêt gracieux de l'ancien conteneur (`docker stop -t 15 sample-app`). Traefik le retire **sur événement Docker**, pas instantanément : cette fenêtre résiduelle produit des requêtes en timeout (~2,5 % des requêtes émises pendant le swap, mesuré). Le moteur ne draine pas l'ancien avant de le stopper — README §2 règle 2.
     * Suppression de l'ancien conteneur et renommage du candidat en `sample-app`.
     * Délai de stabilisation de 2 secondes.

4. **Résultat du test :**
   * **100% de réponses HTTP 200** reçues par le client pendant toute la durée de la mise à jour.
   * **0 seconde d'interruption constatée**.
   * Réponse immédiate de la nouvelle version :
     ```text
     [Sample App] Version: 1.1.0 | Host: 288bf0fb7bc7 | Uptime: 10s
     ```

---

### Phase 3 : Détection d'Anomalie et Rollback Automatique (v1.2.0 cassée)

Cette étape simule une régression critique en production (ex: crash au démarrage, mauvaise configuration, dépendance manquante).

1. **Build et Publication d'une version défaillante :**
   ```bash
   ./env/sample-app/build-and-push.sh 1.2.0 --broken
   ```
   * Le conteneur démarre mais son endpoint `/health` retourne une erreur HTTP 500.

2. **Déroulement du Rollback dans `autodeploy.sh` :**
   * Détection du tag `1.2.0`.
   * Démarrage du candidat `sample-app-candidate`.
   * Surveillance du `HEALTHCHECK` Docker.
   * Le healthcheck échoue et bascule au statut `unhealthy`.
   * **Intervention immédiate du script :**
     1. Détecte le statut `unhealthy`.
     2. Affiche les 30 dernières lignes de logs du conteneur en échec :
        ```text
        [CONTAINER LOG] [Sample App] Démarré sur le port 3000 (Version: 1.2.0, FailHealth: true)
        ```
     3. Détruit et supprime immédiatement le candidat défaillant (`sample-app-candidate`).
     4. **Laisse l'ancien conteneur de production (v1.1.0) intact.**
     5. Envoie une alerte Webhook (si configurée).

3. **Vérification finale :**
   * Traefik continue d'acheminer le trafic vers la version `1.1.0` stable :
     ```bash
     curl http://localhost:9080/
     # Réponse : [Sample App] Version: 1.1.0 | Host: 288bf0fb7bc7 | Uptime: 22s
     ```
   * **Impact utilisateur : ZÉRO.**

---

## 🚀 3. Transposition en Production (GitLab CI + Systemd)

Pour transposer ce workflow validé dans votre infrastructure d'entreprise, voici le mapping direct :

### 1. Côté GitLab CI (`.gitlab-ci.yml`)
Votre pipeline GitLab compile l'application, lui attribue son tag de release (ex: `v1.2.0`) et le pousse vers le GitLab Container Registry interne :

```yaml
stages:
  - build-and-publish

docker-publish:
  stage: build-and-publish
  image: docker:24-cli
  services:
    - docker:24-dind
  rules:
    - if: $CI_COMMIT_TAG =~ /^v[0-9]+\.[0-9]+\.[0-9]+/
  script:
    - docker login -u "$CI_REGISTRY_USER" -p "$CI_REGISTRY_PASSWORD" "$CI_REGISTRY"
    - docker build -t "$CI_REGISTRY_IMAGE:$CI_COMMIT_TAG" .
    - docker push "$CI_REGISTRY_IMAGE:$CI_COMMIT_TAG"
```

### 2. Côté Serveur de Production
1. **Traefik :** Tourne déjà sur votre serveur avec le provider Docker activé sur le réseau `traefik-net`.
2. **Installation :** Vous lancez `sudo ./install.sh`.
3. **Configuration globale (`/etc/autodeploy/autodeploy.env`) :**
   ```bash
   GITLAB_URL="https://gitlab.votre-boite.fr"
   GITLAB_REGISTRY="registry.gitlab.votre-boite.fr"
   GITLAB_USER="deploy-token"
   GITLAB_TOKEN="glpat-xxxxxxxxxxxxxxxxxxxx"
   ```
4. **Déclaration de vos conteneurs (`/etc/autodeploy/apps.d/*.conf`) :**
   Un fichier simple par conteneur indiquant le nom, l'image, l'ID projet GitLab et les arguments `docker run` (labels Traefik et HEALTHCHECK).
5. **Automatisation :** Le timer Systemd (`autodeploy.timer`) exécute le script toutes les 2 minutes de manière totalement transparente.

---

## 📈 4. Matrice de Robustesse

| Événement | Réaction du Système | Résultat en Prod |
|---|---|---|
| **Nouvelle version saine publiée** | Pull, démarrage parallèle, validation du healthcheck, bascule Traefik, extinction propre de l'ancienne version. | **Pas de coupure de service**, mais pas « 0s » : fenêtre résiduelle de ~2,5 % de requêtes en timeout pendant le swap, faute de drain préalable de l'ancien conteneur (README §2 règle 2). Le test à 200ms ne la voit pas passer ; à 50ms, oui. |
| **Nouvelle version avec bug bloquant** | Le healthcheck échoue (`unhealthy`), arrêt et suppression du candidat, capture des logs d'erreur, notification. | **Prod préservée sur l'ancienne version** |
| **Téléchargement d'image très long** | Le verrou `flock` empêche les déclenchements concurrents du timer Systemd. | **Aucun conflit ni collision** |
| **Pas de nouvelle version** | Comparaison du digest/tag actuel avec le distant : sortie immédiate (0 opération Docker inutile). | **Charge CPU/Réseau quasi-nulle** |
| **Remplissage du disque** | Prune automatique des images dangling après chaque cycle. | **Pas de saturation disque** |
