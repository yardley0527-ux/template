# frozen_string_literal: true

module NotificationRules
  # crm_customer_product_trackings.product_key uses JourneyProducts' 8 keys
  # (omnipotent/metabolism/glutathione/collagen/turmeric/qingxian/simi/
  # probiotic). crm_products (the Phase 0A inventory source of truth) uses
  # 13 keys seeded independently — 6 match by string, but "qingxian" (清纖粉)
  # and "simi" (私密粉) were seeded as "cleanse_powder" and "intimate_powder"
  # respectively. Any rule cross-referencing tracking data with
  # crm_products.availability_status MUST go through this map — a naive
  # CrmProduct.find_by(key: tracking.product_key) silently returns nil for
  # these two products and would make them invisible to inventory-context
  # checks (looks like "no matching product" instead of "wrong key").
  module ProductKeyMapping
    TRACKING_TO_CRM_PRODUCT_KEY = {
      "qingxian" => "cleanse_powder",
      "simi"     => "intimate_powder"
    }.freeze

    module_function

    def crm_product_for(tracking_product_key)
      crm_key = TRACKING_TO_CRM_PRODUCT_KEY.fetch(tracking_product_key, tracking_product_key)
      CrmProduct.find_by(key: crm_key)
    end
  end
end
