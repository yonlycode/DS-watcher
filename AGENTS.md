# AGENTS.md

Conseils pour les agents IA qui travaillent sur ce dépôt. Ce fichier ne répète pas
le README : il liste les **pièges vérifiés en pratique**, ceux qui coûtent le plus
cher à découvrir seul.

## Ce qu'est ce dépôt

Moteur de déploiement automatique d'images Docker (`bin/autodeploy.sh`) avec
rolling update zéro-coupure via Traefik, piloté par systemd. Pas d'orchestrateur :
le zéro-downtime repose entièrement sur la correctness des labels Traefik et de la
séquence `run candidat → healthcheck → stop ancien → rename`.

**Langue : tout est en français** (README, docs, commentaires de code, messages de
log). Garder cette cohérence.

## Contraintes de l'environnement de dev

Ce poste est **macOS avec bash 3.2** (pas bash 4+). Conséquences concrètes :

| Binaire | Présent ? | Impact |
|---|---|---|
| `flock` | **non** | Le lock passe par le fallback `mkdir` atomique. Le chemin `flock` n'est **jamais exercé ici**. |
| `timeout` / `gtimeout` | **non** | `run_with_timeout` passe par son watchdog bash. Le chemin `timeout(1)` n'est **jamais exercé ici**. |
| `wget` | non | Le host n'a pas wget, mais les conteneurs Alpine si. Ne pas confondre. |
| `tofu` | oui | `terraform` absent, c'est OpenTofu. |

Ne pas conclure "c'est testé" d'un chemin qui n'existe pas sur ce poste. Les
chemins `flock` et `timeout(1)` ne seront réels que sur le serveur.

`docker build` échoue avec
`failed to update builder last activity time: ... operation not permitted`
quand `~/.docker/buildx` n'est pas inscriptible (sandbox, CI, HOME non persistant).
Parade : `export DOCKER_BUILDKIT=0` (déjà en place dans `demo/` et `env/`).

## Les quatre règles Traefik dures

Enfreindre une de ces règles ne dégrade pas le comportement : **ça coupe le
trafic**. Détail et mesures dans le README §2. Les reconnaître à leur message :

1. **Labels de service strictement identiques entre l'ancien et le candidat.**
   Sinon Traefik supprime le service, tout tombe en 404 :
   `Service defined multiple times with different configurations`
   `the service "x@docker" does not exist`
   Corollaire : changer les labels d'un service existant est une **migration
   coordonnée**, pas un redéploiement. Le moteur n'a **aucune garde** là-dessus.

2. **Le retry est un middleware, pas un champ du load balancer.**
   `loadbalancer.retry.*` (valide en v2) → `field not found, node: retry` →
   service supprimé. `tryDuration` n'existe qu'à partir de v3.1.

3. **Un label invalide fait tomber TOUT le service**, pas seulement ce label.
   Toujours vérifier le rendu réel dans l'API (`/api/http/services`,
   `/api/http/routers`) plutôt que de supposer que les labels sont acceptés.

4. **Un Traefik qui monte le socket Docker voit tous les conteneurs labelisés de
   l'hôte.** Deux `PathPrefix(/)` = départage arbitraire ; un router étranger
   peut gagner et, son backend étant injoignable depuis ce réseau, on obtient
   `503 no available server` **sans que rien soit cassé chez soi**.
   `--providers.docker.network` ne filtre **pas** ce que le provider observe.
   Les options `.filters` / `.label` n'existent pas en v3.0.
   Seules défenses : `priority` explicite, ou règle `Host()` distincte.

## Pièges bash spécifiques à ce code

Le moteur tourne sous `set -euo pipefail` avec bash 3.2. Quatre pièges déjà
rencontrés, tous commentés dans le code — ne pas les réintroduire ailleurs :

- `((x++))` : le post-incrément d'une valeur 0 retourne 1 et **tue le script**.
  Utiliser `x=$((x + 1))`.
- Une substitution de commande qui échoue tue le script sans distinguer
  erreur/vide. Toujours `latest=$(cmd) || rc=$?`.
- Tableau vide sous `set -u` : `${arr[@]}` plante en bash 3.2. Écrire
  `${arr[@]+"${arr[@]}"}`.
- `eval "$cmd"` à plat : un `exit N` dans le code évalué **remonte et tue le
  moteur**, emportant persistance d'état, webhook et nettoyage. D'où
  `( eval "$cmd" )` dans `run_hook`. Même cause pour `read -rp` sur EOF :
  ajouter `|| confirm=""`.

## Hygiène des tests

Leçon la plus coûteuse de la dernière session :

- **Un répertoire de conf par cas de test.** `autodeploy.sh` itère sur *toutes*
  les confs de `apps.d/`. Si plusieurs scénarios partagent le dossier, le premier
  qui échoue (surtout via un hook qui `exit`) empêche les suivants de s'exécuter,
  et on diagnostique le mauvais scénario.
- **Isoler `AUTODEPLOY_STATE_DIR` et `AUTODEPLOY_LOCK_FILE`** par cas, sinon les
  états se polluent et un lock résiduel fait sauter les runs.
- **L'infra du scénario E2E reste active après son exécution** (c'est voulu, le
  script affiche la commande de destruction). Elle collide avec la démo via la
  règle 4. Toujours relancer la démo *avec* l'infra E2E en place pour prouver
  qu'elle y résiste.

## Standard de vérification

**Un test qui ne peut pas échouer ne prouve rien.** Les scripts utilisent un
harness `FAILED` / `pass()` / `fail()` avec exit non nul — le maintenir.

**Ne jamais écrire « zéro downtime » sans donner le taux d'échantillonnage.**
Le pinger de la démo tire à 200ms et affiche 0 erreur. À 50ms, le même swap
échoue sur ~1 requête sur 30. Un score `0/N` sans l'intervalle ni le nombre de
runs est une affirmation vide, pas une mesure.

Quand on ajoute une garde, écrire le scénario qui **la déclenche réellement**.
Les 7 scénarios de gardes (refus sans healthcheck, opt-in, hooks pre/post,
contention de lock, variables exposées, non-fuite d'un `exit` de hook) ont été
ceux qui ont révélé le bug du `eval`/`exit` — le code passait `bash -n` sans.

## État connu — ne pas déclarer résolu

- **Fenêtre résiduelle au swap** : ~3 % des requêtes émises pendant le swap
  sortent en timeout de 2s. Le moteur **ne draine pas** l'ancien conteneur avant
  `docker stop`. Mesures : nginx 3/5 runs, `sample-app` (avec son drain SIGTERM
  1,5s) **5/5 runs, déterministe**, drain moteur avec attente d'éviction 0/5.
  Le remède est côté moteur : attendre `DOWN` dans l'API Traefik avant le stop.
  Le drain côté application **ne suffit pas**.
- **Migration de labels** : documentée, aucune garde, jamais testée de bout en bout.
- **`install.sh` jamais exécuté** : nécessite root + systemd. Uniquement `bash -n`.
- **Chemins `flock` et `timeout(1)` non exercés** sur ce poste.

## Ne pas commiter

`env/sandbox/`, `**/*.tfstate*`, `**/*.log`, `*.lock`, `*.lockdir`, `*.env`
(sauf les `.example`) — déjà couverts par `.gitignore`. Vérifier
`git status --porcelain` avant un commit : les runs de test laissent des
artefacts.

## Commandes

```bash
bash -n bin/autodeploy.sh              # syntaxe (nécessaire, jamais suffisant)
./demo/test-local-simulation.sh        # démo autonome, ~40s
./env/test-full-scenario.sh            # E2E complet IaC+registry+Traefik, ~2min
                                     # laisse l'infra active :
(cd env/terraform && tofu destroy -auto-approve)

autodeploy.sh --status                 # table apps / local / distant / échecs
autodeploy.sh --reset-failed <app>     # purge l'état d'échec
autodeploy.sh --force <app>            # redéploie malgré un tag en échec
```
