# frozen_string_literal: true

# Resolves a raw product_name string to its CrmProduct using the confirmed
# entries in product_name_mappings.  This is the Single-Source-of-Truth lookup
# that should replace all inline `product_name LIKE '%…%'` queries as Epic C
# progresses.
#
# Usage:
#   ProductNameResolver.resolve("薑黃3")       # => #<CrmProduct key="turmeric">
#   ProductNameResolver.resolve_key("全能6")    # => "omnipotent"
#   ProductNameResolver.resolve_batch(["薑黃3", "全能6"])
#   # => { "薑黃3" => <CrmProduct turmeric>, "全能6" => <CrmProduct omnipotent> }
#   ProductNameResolver.orders_for("turmeric")  # => ShoplineOrder scope
class ProductNameResolver
  # Returns the CrmProduct for a single raw name, or nil if unmapped.
  def self.resolve(raw_name)
    ProductNameMapping.resolve(raw_name)
  end

  # Returns only the product key string, or nil.
  def self.resolve_key(raw_name)
    resolve(raw_name)&.key
  end

  # Returns { raw_name => CrmProduct } for a collection.
  # Names with no confirmed mapping are absent from the result.
  def self.resolve_batch(raw_names)
    ProductNameMapping.resolve_batch(raw_names)
  end

  # Returns a ShoplineOrder scope for all orders belonging to product_key.
  #
  # Epic C Phase 3A: supports two hit paths:
  #   1. Primary product: product_name_mappings.crm_product_id = crm_products.id
  #   2. Bundle component: product_mapping_components.crm_product_id = crm_products.id
  #
  # This means "代謝錠1薑黃1" (primary = metabolism, component turmeric added later)
  # will appear in BOTH orders_for("metabolism") AND orders_for("turmeric") once
  # its bundle components are populated (Phase 3B).
  #
  # SQL injection safety: crm_product_id is looked up by key in Ruby first;
  # the integer id is interpolated into SQL, never the raw user-supplied string.
  def self.orders_for(product_key)
    crm = CrmProduct.find_by(key: product_key.to_s)
    return ShoplineOrder.none unless crm

    crm_id = crm.id  # integer — safe to interpolate

    ShoplineOrder.joins(<<~SQL.squish)
      INNER JOIN product_name_mappings pnm
        ON pnm.raw_name    = shopline_orders.product_name
       AND pnm.mapping_status = 'confirmed_alias'
    SQL
    .where(<<~SQL.squish, crm_id, crm_id)
      pnm.crm_product_id = ?
      OR EXISTS (
        SELECT 1 FROM product_mapping_components pmc
        WHERE pmc.product_name_mapping_id = pnm.id
          AND pmc.crm_product_id = ?
      )
    SQL
  end
end
