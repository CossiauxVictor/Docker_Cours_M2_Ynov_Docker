#!/usr/bin/env bash
# measure-downtime.sh [DUREE_s] - envoie RATE req/s sur /health a travers traefik et compte les echecs
#
#   ./deploy/measure-downtime.sh 60          (dans un 2e terminal : le deploiement a mesurer)
#
# Le client tourne dans un conteneur node sur le reseau shop_front (comme un vrai client derriere le proxy) :
# depuis Git Bash, lancer 100 curl/s c'est impossible (un curl = ~20 ms de lancement sous Windows).
# Une ligne par seconde : requetes OK / KO + la version servie (GET / toutes les secondes).
# Code retour : 0 si aucun echec, 1 sinon.
set -euo pipefail

DURATION="${1:-60}"
RATE="${RATE:-100}"
NET="${NET:-shop_front}"
TARGET="${TARGET:-traefik}"          # le proxy, pas l'api en direct
HOST_HEADER="${HOST_HEADER:-api.localhost}"

read -r -d '' JS <<'EOF' || true
const http = require('http');
const [duration, rate, target, host] = [+process.env.DURATION, +process.env.RATE, process.env.TARGET, process.env.HOST_HEADER];
// keep-alive comme un vrai client / navigateur : c'est le cas difficile (connexions deja ouvertes vers l'ancien conteneur)
const agent = new http.Agent({ keepAlive: true, maxSockets: 50 });
let sec = { ok: 0, ko: 0, codes: {} }, total = { ok: 0, ko: 0, codes: {} }, version = '?';
function req(path, cb) {
  const r = http.get({ host: target, port: 80, path, agent, headers: { Host: host }, timeout: 2000 }, (res) => {
    let body = ''; res.on('data', (c) => (body += c)); res.on('end', () => cb(null, res.statusCode, body));
  });
  r.on('timeout', () => r.destroy(new Error('timeout')));
  r.on('error', (e) => cb(e));
}
function count(err, code) {
  const k = err ? (err.code || err.message) : code;
  if (!err && code === 200) { sec.ok++; total.ok++; return; }
  sec.ko++; total.ko++; sec.codes[k] = (sec.codes[k] || 0) + 1; total.codes[k] = (total.codes[k] || 0) + 1;
}
const t0 = Date.now(); let s = 0;
const tick = setInterval(() => req('/health', count), 1000 / rate);
const report = setInterval(() => {
  s++;
  req('/', (e, c, b) => { try { version = JSON.parse(b).version; } catch { version = e ? 'injoignable' : `HTTP ${c}`; } });
  const ko = sec.ko ? ` KO=${sec.ko} ${JSON.stringify(sec.codes)}` : '';
  console.log(`t=${String(s).padStart(3)}s ok=${String(sec.ok).padStart(3)}${ko}  version=${version}`);
  sec = { ok: 0, ko: 0, codes: {} };
  if (Date.now() - t0 >= duration * 1000) {
    clearInterval(tick); clearInterval(report);
    setTimeout(() => {
      console.log(`\nTOTAL ${total.ok + total.ko} requetes : ${total.ok} OK, ${total.ko} ECHECS ${total.ko ? JSON.stringify(total.codes) : ''}`);
      process.exit(total.ko ? 1 : 0);
    }, 2500);
  }
}, 1000);
EOF

echo "mesure : ${RATE} req/s sur http://${TARGET}/health (Host: ${HOST_HEADER}) pendant ${DURATION}s, reseau ${NET}"
MSYS_NO_PATHCONV=1 docker run --rm --network "$NET" \
  -e DURATION="$DURATION" -e RATE="$RATE" -e TARGET="$TARGET" -e HOST_HEADER="$HOST_HEADER" \
  node:20.20.2-alpine3.22 node -e "$JS"
