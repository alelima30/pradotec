/* ============================================================
   PRADOTEC PISCINAS — site behaviour
   ============================================================ */

/* ---- Splash / abertura -------------------------------------------------
   Logo anima, barra carrega, depois a cortina sobe revelando o site.
   Timers em JS (não só CSS) para nunca travar a página escondida. ---- */
(function () {
  const splash = document.getElementById("splash");
  if (!splash) return;
  document.body.classList.add("splash-lock");
  function finish() {
    if (splash.classList.contains("done")) return;
    splash.classList.add("done");
    document.body.classList.remove("splash-lock");
    setTimeout(() => splash.classList.add("gone"), 950);
  }
  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  setTimeout(finish, reduced ? 900 : 2450);
  // Failsafe absoluto: nunca deixe a tela presa na abertura.
  setTimeout(finish, 5000);
  // Pular com clique/tecla
  splash.addEventListener("click", finish);
  window.addEventListener("keydown", finish, { once: true });
})();

/* ---- WhatsApp config -------------------------------------------------
   Formato internacional, só dígitos: 55 (Brasil) + DDD + número.
   Número real: (11) 9 3399-3340
--------------------------------------------------------------------- */
const WHATSAPP_NUMBER = "5511933993340";
const WHATSAPP_MSG = encodeURIComponent(
  "Olá! Vim pelo site da Pradotec Piscinas e gostaria de solicitar um orçamento."
);
document.querySelectorAll(".wa-link").forEach((a) => {
  a.setAttribute("href", `https://wa.me/${WHATSAPP_NUMBER}?text=${WHATSAPP_MSG}`);
  a.setAttribute("target", "_blank");
  a.setAttribute("rel", "noopener");
});

/* ---- Year ---- */
const yearEl = document.getElementById("year");
if (yearEl) yearEl.textContent = new Date().getFullYear();

/* ---- Nav scroll state ---- */
const nav = document.getElementById("nav");
function onScroll() {
  if (window.scrollY > 40) nav.classList.add("scrolled");
  else nav.classList.remove("scrolled");
}
onScroll();
window.addEventListener("scroll", onScroll, { passive: true });

/* ---- Mobile menu ---- */
const burger = document.getElementById("burger");
const mobileMenu = document.getElementById("mobileMenu");
function closeMenu() {
  mobileMenu.classList.remove("open");
  document.body.style.overflow = "";
}
if (burger) {
  burger.addEventListener("click", () => {
    const open = mobileMenu.classList.toggle("open");
    document.body.style.overflow = open ? "hidden" : "";
  });
  mobileMenu.querySelectorAll("a").forEach((a) =>
    a.addEventListener("click", closeMenu)
  );
}

/* ---- Reveal on scroll ---- */
const revealEls = Array.from(document.querySelectorAll(".reveal"));
function revealInView() {
  const h = window.innerHeight || document.documentElement.clientHeight;
  revealEls.forEach((el) => {
    if (el.classList.contains("in")) return;
    const r = el.getBoundingClientRect();
    if (r.top < h * 0.92 && r.bottom > 0) el.classList.add("in");
  });
}
revealInView();
if ("IntersectionObserver" in window) {
  const io = new IntersectionObserver(
    (entries) => {
      entries.forEach((e) => {
        if (e.isIntersecting) {
          e.target.classList.add("in");
          io.unobserve(e.target);
        }
      });
    },
    { threshold: 0.1, rootMargin: "0px 0px -6% 0px" }
  );
  revealEls.forEach((el) => { if (!el.classList.contains("in")) io.observe(el); });
} else {
  window.addEventListener("scroll", revealInView, { passive: true });
}

/* ---- Before / After sliders ---- */
function initBA(root) {
  const before = root.querySelector("[data-before]");
  const handle = root.querySelector("[data-handle]");
  if (!before || !handle) return;
  const beforeImg = before.querySelector("img");
  let dragging = false;

  function syncWidth() {
    // Keep the "before" image at the full board width so it is clipped, not squished.
    if (beforeImg) beforeImg.style.width = root.clientWidth + "px";
  }
  function setPos(clientX) {
    const rect = root.getBoundingClientRect();
    let pct = ((clientX - rect.left) / rect.width) * 100;
    pct = Math.max(2, Math.min(98, pct));
    before.style.width = pct + "%";
    handle.style.left = pct + "%";
  }
  // initial position
  before.style.width = "50%";
  handle.style.left = "50%";
  syncWidth();
  window.addEventListener("resize", syncWidth, { passive: true });

  const start = (e) => {
    dragging = true;
    root.style.cursor = "ew-resize";
    setPos((e.touches ? e.touches[0] : e).clientX);
  };
  const move = (e) => {
    if (!dragging) return;
    if (e.cancelable) e.preventDefault();
    setPos((e.touches ? e.touches[0] : e).clientX);
  };
  const end = () => {
    dragging = false;
    root.style.cursor = "";
  };

  handle.addEventListener("mousedown", start);
  root.addEventListener("mousedown", start);
  window.addEventListener("mousemove", move);
  window.addEventListener("mouseup", end);
  handle.addEventListener("touchstart", start, { passive: true });
  root.addEventListener("touchstart", start, { passive: true });
  window.addEventListener("touchmove", move, { passive: false });
  window.addEventListener("touchend", end);
}
document.querySelectorAll("[data-ba]").forEach(initBA);

/* ---- Água cristalina 3D (WebGL) — fundo em tela cheia do hero ----
   Cáusticas de luz animadas nas cores da marca; loop infinito e leve.
   Sem WebGL, a camada é removida e fica o gradiente CSS do hero. ---- */
function initWater3D(canvas) {
  const gl = canvas.getContext("webgl", { antialias: false, alpha: false, powerPreference: "low-power" });
  if (!gl) return false;

  const VERT = "attribute vec2 a;void main(){gl_Position=vec4(a,0.,1.);}";
  const FRAG = `
precision highp float;
uniform float u_time;
uniform vec2 u_res;
void main(){
  vec2 uv = gl_FragCoord.xy / u_res;
  vec2 p = mod(uv * vec2(u_res.x / u_res.y, 1.0) * 6.2831853, 6.2831853) - 250.0;
  float t = u_time * 0.5 + 23.0;
  vec2 i = p;
  float c = 1.0;
  const float inten = 0.005;
  for (int n = 0; n < 5; n++) {
    float tt = t * (1.0 - (3.5 / float(n + 1)));
    i = p + vec2(cos(tt - i.x) + sin(tt + i.y), sin(tt - i.y) + cos(tt + i.x));
    c += 1.0 / length(vec2(p.x / (sin(i.x + tt) / inten), p.y / (cos(i.y + tt) / inten)));
  }
  c /= 5.0;
  c = 1.17 - pow(c, 1.4);
  float glow = pow(abs(c), 8.0);
  /* gradiente da marca: navy-950 -> navy -> respiro ciano no topo */
  vec3 deep = vec3(0.004, 0.082, 0.212);
  vec3 mid  = vec3(0.000, 0.231, 0.557);
  vec3 base = mix(deep, mid, smoothstep(0.0, 1.0, uv.y));
  base += vec3(0.0, 0.16, 0.24) * smoothstep(0.55, 1.05, uv.y);
  /* cáusticas em ciano (#21d2ff) com pico quase branco */
  vec3 caustic = vec3(0.129, 0.824, 1.0) * glow + vec3(0.55) * pow(glow, 3.0);
  gl_FragColor = vec4(clamp(base + caustic, 0.0, 1.0), 1.0);
}`;

  function compile(type, src) {
    const s = gl.createShader(type);
    gl.shaderSource(s, src);
    gl.compileShader(s);
    return gl.getShaderParameter(s, gl.COMPILE_STATUS) ? s : null;
  }
  const vs = compile(gl.VERTEX_SHADER, VERT);
  const fs = compile(gl.FRAGMENT_SHADER, FRAG);
  if (!vs || !fs) return false;
  const prog = gl.createProgram();
  gl.attachShader(prog, vs);
  gl.attachShader(prog, fs);
  gl.linkProgram(prog);
  if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) return false;
  gl.useProgram(prog);

  // triângulo cobrindo a tela inteira
  gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
  const loc = gl.getAttribLocation(prog, "a");
  gl.enableVertexAttribArray(loc);
  gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
  const uTime = gl.getUniformLocation(prog, "u_time");
  const uRes = gl.getUniformLocation(prog, "u_res");

  function resize() {
    // resolução reduzida: cáusticas são suaves, não precisam de pixel perfeito
    const scale = Math.min(window.devicePixelRatio || 1, 1.5) * 0.6;
    const w = Math.max(1, Math.round(canvas.clientWidth * scale));
    const h = Math.max(1, Math.round(canvas.clientHeight * scale));
    if (canvas.width !== w || canvas.height !== h) {
      canvas.width = w;
      canvas.height = h;
      gl.viewport(0, 0, w, h);
    }
  }
  function draw(seconds) {
    resize();
    gl.uniform1f(uTime, seconds);
    gl.uniform2f(uRes, canvas.width, canvas.height);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }

  if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
    requestAnimationFrame(() => draw(12)); // um quadro estático bonito
  } else {
    (function loop(ms) {
      // não desenha se o quadro estiver oculto (ex.: mobile esconde o hero-media)
      if (canvas.offsetParent !== null) draw(ms / 1000);
      requestAnimationFrame(loop);
    })(0);
  }
  return true;
}
(function () {
  const layer = document.getElementById("heroWater");
  if (!layer) return;
  const canvas = document.getElementById("water3d");
  if (!canvas || !initWater3D(canvas)) layer.remove();
})();

/* ---- Vídeo de fundo do "Sobre" ----
   Ao rolar até a seção, o vídeo da cachoeira surge com transição
   (fade + leve zoom) e começa a tocar; fora da tela ele pausa. ---- */
(function () {
  const sec = document.getElementById("sobre");
  const vid = document.getElementById("aboutVideo");
  if (!sec || !vid) return;
  vid.muted = true; // garante autoplay permitido em todos os navegadores
  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  function enter() {
    sec.classList.add("video-in");
    if (!reduced) vid.play().catch(() => {});
  }
  if ("IntersectionObserver" in window) {
    new IntersectionObserver((entries) => {
      entries.forEach((e) => {
        if (e.isIntersecting) enter();
        else vid.pause();
      });
    }, { threshold: 0.18 }).observe(sec);
  } else {
    enter();
  }
})();

/* ---- Hero carousel (auto-advancing fade slideshow) ---- */
function initCarousel(root) {
  const slides = Array.from(root.querySelectorAll(".car-slide"));
  const dotsWrap = root.querySelector(".car-dots");
  if (slides.length < 2) return;
  const interval = parseInt(root.getAttribute("data-interval"), 10) || 3500;
  let i = 0;
  let timer = null;

  // build dots
  const dots = slides.map((_, idx) => {
    const b = document.createElement("button");
    b.type = "button";
    b.setAttribute("aria-label", "Foto " + (idx + 1));
    b.addEventListener("click", () => { go(idx); restart(); });
    dotsWrap.appendChild(b);
    return b;
  });

  function go(n) {
    i = (n + slides.length) % slides.length;
    slides.forEach((s, idx) => s.classList.toggle("is-active", idx === i));
    dots.forEach((d, idx) => d.classList.toggle("is-active", idx === i));
  }
  function next() { go(i + 1); }
  function start() { timer = setInterval(next, interval); }
  function restart() { if (timer) clearInterval(timer); start(); }

  go(0);
  start();

  // pause on hover (desktop nicety)
  root.addEventListener("mouseenter", () => { if (timer) clearInterval(timer); });
  root.addEventListener("mouseleave", restart);
}
document.querySelectorAll(".carousel").forEach(initCarousel);
