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

  # Returns a scope of ShoplineOrder for a given product_key using the
  # ProductNameMapping join — the Registry-driven replacement for
  # `ShoplineOrder.where(product_sql)`.
  def self.orders_for(product_key)
    ShoplineOrder
      .joins(
        "INNER JOIN product_name_mappings pnm ON pnm.raw_name = shopline_orders.product_name
           AND pnm.mapping_status = 'confirmed_alias'
         INNER JOIN crm_products cp ON cp.id = pnm.crm_product_id
           AND cp.key = #{ActiveRecord::Base.connection.quote(product_key.to_s)}"
      )
  end
end
