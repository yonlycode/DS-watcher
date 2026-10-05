const http = require('http');
const os = require('os');

const PORT = process.env.PORT || 3000;
const VERSION = process.env.APP_VERSION || '1.0.0';
const FAIL_HEALTH = process.env.FAIL_HEALTH === 'true';

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
  res.end(`[Sample App] Version: ${VERSION} | Host: ${os.hostname()} | Uptime: ${Math.floor(process.uptime())}s\n`);
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`[Sample App] Démarré sur le port ${PORT} (Version: ${VERSION}, FailHealth: ${FAIL_HEALTH})`);
});

process.on('SIGTERM', () => {
  console.log('[Sample App] Réception SIGTERM, arrêt gracieux...');
  server.close(() => process.exit(0));
});
