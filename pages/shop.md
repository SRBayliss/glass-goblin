---
layout: default
title: Shop
permalink: /shop
---
{% assign products = site.products | sort: 'sku' %}
{% assign cats = site.products | map: 'category' | uniq | sort %}

# Shop

One-off and small-batch pieces, listed here first — each is unique, so once it's gone, it's gone.

<div class="shop-filters">
  <input type="search" class="shop-filter__search" placeholder="Search…" aria-label="Search products">
  <select class="shop-filter__category" aria-label="Filter by category">
    <option value="">All categories</option>
    {% for c in cats %}{% if c and c != "" %}<option value="{{ c }}">{{ c }}</option>{% endif %}{% endfor %}
  </select>
  <input type="number" class="shop-filter__maxprice" min="0" step="0.5" placeholder="Max £" aria-label="Maximum price in pounds">
  <label class="shop-filter__toggle"><input type="checkbox" class="shop-filter__instock"> In stock only</label>
  <label class="shop-filter__toggle"><input type="checkbox" class="shop-filter__uv"> Glows under UV</label>
</div>

<div class="shop-grid">
{% for product in products %}<a class="shop-card{% if product.status == 'sold' %} shop-card--sold{% endif %}" href="{{ product.url | relative_url }}" data-title="{{ product.title | downcase }}" data-category="{{ product.category }}" data-tags="{{ product.tags | join: ' ' }}" data-price="{{ product.price }}" data-stock="{% if product.status == 'sold' %}0{% else %}{{ product.quantity | default: 1 }}{% endif %}">
    <span class="shop-card__image">{% if product.images and product.images != empty %}<img src="{{ product.images[0] | relative_url }}" alt="{{ product.title }}" loading="lazy">{% endif %}{% if product.status == 'sold' %}<span class="shop-card__badge">Sold</span>{% endif %}</span>
    <span class="shop-card__body">
      <span class="shop-card__title">{{ product.title }}</span>
      <span class="shop-card__price">{% include price.html amount=product.price %}{% if product.quantity and product.quantity > 1 %} each{% endif %}</span>
    </span>
  </a>{% endfor %}
</div>

<p class="shop-empty" hidden>No pieces match your filters.</p>

<script src="{{ '/assets/js/shop-filter.js' | relative_url }}" defer></script>
