# frozen_string_literal: true

# Single write path for all ProductNameMapping history.
#
# Call this from BulkConfirmService, BulkIgnoreService, ManualReview UI, etc.
# Never scatter ProductNameMappingLog.create! calls across callers.
#
# Usage:
#   log = ProductNameMappingHistoryService.record!(
#     mapping:              mapping,
#     action:               :bulk_confirm,
#     change_source:        :bulk_confirm,
#     from_status:          "pending",
#     to_status:            "confirmed_alias",
#     old_crm_product_id:   nil,
#     new_crm_product_id:   crm_product.id,
#     performed_by_user_id: current_user.id,
#     notes:                "Bulk confirm via Review Workflow"
#   )
#
# mapping_version is computed automatically via mapping.next_mapping_version.
# Raises ActiveRecord::RecordInvalid if the log fails validation.
class ProductNameMappingHistoryService
  def self.record!(
    mapping:,
    action:,
    change_source:,
    from_status:,
    to_status:,
    old_crm_product_id:   nil,
    new_crm_product_id:   nil,
    performed_by_user_id: nil,
    notes:                nil
  )
    ProductNameMappingLog.create!(
      product_name_mapping: mapping,
      mapping_version:      mapping.next_mapping_version,
      action:               action.to_s,
      change_source:        change_source.to_s,
      from_status:          from_status,
      to_status:            to_status,
      old_crm_product_id:   old_crm_product_id,
      new_crm_product_id:   new_crm_product_id,
      performed_by_user_id: performed_by_user_id,
      notes:                notes
    )
  end
end
