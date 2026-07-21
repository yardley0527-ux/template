# frozen_string_literal: true

# Read model for crm_customer_product_trackings (Phase 2A rollup output —
# written exclusively via raw SQL upsert by CrmCustomerProductTrackingRefreshService,
# never through this class). Added for NotificationRules to query with normal
# ActiveRecord scopes instead of hand-writing SQL for every rule.
class CrmCustomerProductTracking < ApplicationRecord
  self.table_name = "crm_customer_product_trackings"
end
