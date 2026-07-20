---
layout: default
title: Shop
permalink: /shop
---
# Shop

One-off and small-batch pieces, listed here first — each is unique, so once it's gone, it's gone.

<div class="shop-grid">
{%- assign products = site.products | sort: 'sku' -%}
{%- for product in products -%}
  <a class="shop-card{% if product.status == 'sold' %} shop-card--sold{% endif %}" href="{{ product.url | relative_url }}">
    <span class="shop-card__image">
      {%- if product.images and product.images != empty -%}
      <img src="{{ product.images[0] | relative_url }}" alt="{{ product.title }}" loading="lazy">
      {%- endif -%}
      {%- if product.status == 'sold' -%}<span class="shop-card__badge">Sold</span>{%- endif -%}
    </span>
    <span class="shop-card__body">
      <span class="shop-card__title">{{ product.title }}</span>
      <span class="shop-card__price">{% include price.html amount=product.price %}</span>
    </span>
  </a>
{%- endfor -%}
</div>
