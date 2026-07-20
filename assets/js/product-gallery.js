// Product gallery lightbox — dependency-free, vanilla JS.
// Each .product-gallery carries the full image list in data-images (JSON); the mosaic
// only renders the first few tiles. Clicking any tile opens a shared full-screen viewer
// with prev/next, keyboard (Esc / arrows), swipe, and click-to-zoom. See product.html.
(function () {
  var galleries = [].slice.call(document.querySelectorAll('.product-gallery[data-images]'));
  if (!galleries.length) return;

  // One shared lightbox for the page.
  var lb = document.createElement('div');
  lb.className = 'lightbox';
  lb.setAttribute('role', 'dialog');
  lb.setAttribute('aria-modal', 'true');
  lb.setAttribute('aria-label', 'Image viewer');
  lb.innerHTML =
    '<span class="lightbox__counter" aria-live="polite"></span>' +
    '<button type="button" class="lightbox__btn lightbox__close" aria-label="Close viewer">✕</button>' +
    '<button type="button" class="lightbox__btn lightbox__prev" aria-label="Previous image">‹</button>' +
    '<img class="lightbox__img" alt="">' +
    '<button type="button" class="lightbox__btn lightbox__next" aria-label="Next image">›</button>';
  document.body.appendChild(lb);

  var imgEl = lb.querySelector('.lightbox__img');
  var counterEl = lb.querySelector('.lightbox__counter');
  var prevBtn = lb.querySelector('.lightbox__prev');
  var nextBtn = lb.querySelector('.lightbox__next');
  var urls = [];
  var idx = 0;
  var lastFocus = null;

  function preload(n) {
    var u = urls[(n + urls.length) % urls.length];
    if (u) { var p = new Image(); p.src = u; }
  }

  function show(i) {
    idx = (i + urls.length) % urls.length;
    imgEl.classList.remove('is-zoomed');
    imgEl.src = urls[idx];
    counterEl.textContent = (idx + 1) + ' / ' + urls.length;
    var single = urls.length < 2;
    prevBtn.hidden = single;
    nextBtn.hidden = single;
    preload(idx + 1);
    preload(idx - 1);
  }

  function open(list, i) {
    urls = list;
    lastFocus = document.activeElement;
    lb.classList.add('is-open');
    document.body.style.overflow = 'hidden';
    show(i);
    (urls.length > 1 ? nextBtn : lb.querySelector('.lightbox__close')).focus();
  }

  function close() {
    lb.classList.remove('is-open');
    document.body.style.overflow = '';
    imgEl.src = '';
    if (lastFocus && lastFocus.focus) lastFocus.focus();
  }

  lb.querySelector('.lightbox__close').addEventListener('click', close);
  prevBtn.addEventListener('click', function (e) { e.stopPropagation(); show(idx - 1); });
  nextBtn.addEventListener('click', function (e) { e.stopPropagation(); show(idx + 1); });
  lb.addEventListener('click', function (e) { if (e.target === lb) close(); });
  imgEl.addEventListener('click', function (e) { e.stopPropagation(); imgEl.classList.toggle('is-zoomed'); });

  document.addEventListener('keydown', function (e) {
    if (!lb.classList.contains('is-open')) return;
    if (e.key === 'Escape') close();
    else if (e.key === 'ArrowRight') show(idx + 1);
    else if (e.key === 'ArrowLeft') show(idx - 1);
  });

  // Touch swipe (horizontal).
  var sx = 0, sy = 0;
  lb.addEventListener('touchstart', function (e) { sx = e.touches[0].clientX; sy = e.touches[0].clientY; }, { passive: true });
  lb.addEventListener('touchend', function (e) {
    var dx = e.changedTouches[0].clientX - sx;
    var dy = e.changedTouches[0].clientY - sy;
    if (Math.abs(dx) > 40 && Math.abs(dx) > Math.abs(dy)) show(idx + (dx < 0 ? 1 : -1));
  }, { passive: true });

  galleries.forEach(function (g) {
    var list;
    try { list = JSON.parse(g.getAttribute('data-images')); } catch (e) { list = []; }
    if (!list.length) return;
    g.addEventListener('click', function (e) {
      var tile = e.target.closest('.product-gallery__tile');
      if (!tile) return;
      e.preventDefault();
      open(list, parseInt(tile.getAttribute('data-index'), 10) || 0);
    });
  });
})();
