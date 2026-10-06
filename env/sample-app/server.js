const http = require('http');
const os = require('os');

const PORT = process.env.PORT || 3000;
const VERSION = process.env.APP_VERSION || '1.0.0';
const FAIL_HEALTH = process.env.FAIL_HEALTH === 'true';
// Marqueur de build : change le CONTENU servi sans changer le tag. Sert à prouver
// qu'un re-push du MÊME tag avec contenu différent est bien redéployé (Phase 4/5).
const MARKER = process.env.BUILD_MARKER || 'none';

const server = http.createServer((req, res) => {
  if (req.url === '/health') {
    if (FAIL_HEALTH) {
      res.writeHead(500, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ status: 'unhealthy', version: VERSION, error: 'Simulated failure' }));
    }
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ status: 'healthy', version: VERSION }));
  }

  // Route principale
  res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
  res.end(`[Sample App] Version: ${VERSION} | Marker: ${MARKER} | Host: ${os.hostname()} | Uptime: ${Math.floor(process.uptime())}s\n`);
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`[Sample App] Démarré sur le port ${PORT} (Version: ${VERSION}, FailHealth: ${FAIL_HEALTH})`);
});

process.on('SIGTERM', () => {
  console.log('[Sample App] Réception SIGTERM, arrêt gracieux...');
  // IMPORTANT pour le zéro-downtime avec Traefik : on NE ferme PAS le listener
  // immédiatement. `server.close()` arrête d'accepter les nouvelles connexions
  // tout de suite, or Traefik continue de router vers nous jusqu'à l'événement
  // Docker 'die' → les nouvelles requêtes tombent en 502/504.
  // On garde donc le serveur ACCEPTANT pendant le drain (le candidat sert déjà le
  // trafic), puis on sort. La sortie déclenche le 'die' qui retire ce backend.
  setTimeout(() => {
    server.close(() => process.exit(0)); // stoppe l'accept, draine l'existant, sort
  }, 1500);
});
