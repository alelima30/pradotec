/* Pradotec Piscinas — Service Worker (PWA) */
const CACHE = 'pradotec-v1';

const PRECACHE = [
  './',
  './index.html',
  './styles.css',
  './site.js',
  './manifest.webmanifest',
  './pradotec_logo.png',
  './icon-192.png',
  './icon-512.png',
  './hero-1.svg',
  './hero-2.svg',
  './hero-3.svg',
  './hero-4.svg',
  './hero-5.svg',
  './sobre.svg',
  './antes-1.svg',
  './antes-2.svg',
  './antes-3.svg',
  './depois-1.svg',
  './depois-2.svg',
  './depois-3.svg'
];

self.addEventListener('install', (e) => {
  e.waitUntil(
    caches.open(CACHE).then((c) => c.addAll(PRECACHE)).then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;

  const url = new URL(req.url);

  // HTML: network-first (sempre tenta a versão mais nova, cai no cache offline)
  if (req.mode === 'navigate' || url.pathname.endsWith('.html')) {
    e.respondWith(
      fetch(req)
        .then((res) => {
          const copy = res.clone();
          caches.open(CACHE).then((c) => c.put(req, copy));
          return res;
        })
        .catch(() => caches.match(req).then((r) => r || caches.match('./index.html')))
    );
    return;
  }

  // Vídeo: network-only (muito pesado para cache; evita problemas com range requests)
  if (url.pathname.endsWith('.mp4')) return;

  // Demais assets: cache-first
  e.respondWith(
    caches.match(req).then((cached) => {
      if (cached) return cached;
      return fetch(req).then((res) => {
        if (res.ok && url.origin === location.origin) {
          const copy = res.clone();
          caches.open(CACHE).then((c) => c.put(req, copy));
        }
        return res;
      });
    })
  );
});
