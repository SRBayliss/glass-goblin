// Client-side shop filtering/search — hand-rolled, no dependencies.
// Reads data-* attributes on each .shop-card and shows/hides cards as filters change.
// Facets: free-text search (title/tags/category), category, max price, in-stock, glows-under-UV.
// See pages/shop.md.
(function () {
  var grid = document.querySelector('.shop-grid');
  if (!grid) return;
  var cards = [].slice.call(grid.querySelectorAll('.shop-card'));
  var search = document.querySelector('.shop-filter__search');
  var category = document.querySelector('.shop-filter__category');
  var maxprice = document.querySelector('.shop-filter__maxprice');
  var instock = document.querySelector('.shop-filter__instock');
  var uv = document.querySelector('.shop-filter__uv');
  var empty = document.querySelector('.shop-empty');

  function apply() {
    var q = ((search && search.value) || '').trim().toLowerCase();
    var cat = (category && category.value) || '';
    var max = maxprice ? parseFloat(maxprice.value) : NaN;
    var onlyStock = instock && instock.checked;
    var onlyUv = uv && uv.checked;
    var shown = 0;

    cards.forEach(function (card) {
      var d = card.dataset;
      var hay = (d.title || '') + ' ' + (d.tags || '') + ' ' + (d.category || '').toLowerCase();
      var ok = true;
      if (q && hay.indexOf(q) === -1) ok = false;
      if (cat && d.category !== cat) ok = false;
      if (!isNaN(max) && parseFloat(d.price || '0') > max) ok = false;
      if (onlyStock && parseInt(d.stock || '0', 10) <= 0) ok = false;
      if (onlyUv && (' ' + (d.tags || '') + ' ').indexOf(' uv-glow ') === -1) ok = false;
      card.hidden = !ok;
      if (ok) shown++;
    });

    if (empty) empty.hidden = shown !== 0;
  }

  [search, maxprice].forEach(function (el) { if (el) el.addEventListener('input', apply); });
  [category, instock, uv].forEach(function (el) { if (el) el.addEventListener('change', apply); });
  apply();
})();
