/* Pradotec Piscinas — Service Worker (PWA) */
const CACHE = 'pradotec-v1';

const PRECACHE = [
  './',
  './index.html',
  './styles.css',
  './site.js',
  './manifest.webmanifest',
  './assets/pradotec_logo.png',
  './assets/icons/icon-192.png',
  './assets/icons/icon-512.png',
  './assets/img/hero-1.svg',
  './assets/img/hero-2.svg',
  './assets/img/hero-3.svg',
  './assets/img/hero-4.svg',
  './assets/img/hero-5.svg',
  './assets/img/sobre.svg',
  './assets/img/antes-1.svg',
  './assets/img/antes-2.svg',
  './assets/img/antes-3.svg',
  './assets/img/depois-1.svg',
  './assets/img/depois-2.svg',
  './assets/img/depois-3.svg'
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
