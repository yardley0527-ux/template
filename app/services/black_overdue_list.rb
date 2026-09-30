# frozen_string_literal: true

# 「客戶商機」分頁的黑卡逾期未回購名單：依產品分組，一人一列，讓老闆直接在畫面上維護
# （記聯絡狀態、寫備註），不用下載表格。
#
# 名單本身由 NotificationCustomerListService 即時算（黑卡、逾期 1–60 天、已回購就不出現、
# 累積消費高的排前面）；維護狀態沿用回購追蹤的 CrmCustomerProductCycle／
# CrmCustomerProductFollowUpEvent，跟回購追蹤 Dashboard 是同一份資料，不另開一套。
class BlackOverdueList
  Group = Struct.new(:product_key, :label, :rows, keyword_init: true)

  # 名單頁能做的動作（值是 CrmCustomerProductFollowUpEvent 的 action）。
  ACTIONS = {
    "contacted_waiting_reply" => "已聯絡，等待回覆",
    "no_response"             => "沒有回覆",
    "not_needed"              => "暫時不需要",
    "paused"                  => "暫停追蹤",
    "repurchased"             => "已回購",
    "note_only"               => "只寫備註"
  }.freeze

  # 這兩種狀態代表這位客人已經處理完，列表沉到最下面。
  DONE_STATUSES = %w[paused repurchased].freeze

  def self.call
    new.call
  end

  def call
    NotificationRules::BlackOverdue.eligible_product_keys.filter_map do |key|
      rows = rows_for(key)
      next if rows.empty?

      Group.new(product_key: key, label: JourneyProducts::PRODUCTS.dig(key, :label) || key, rows: rows)
    end
  end

  private

  def rows_for(product_key)
    query = NotificationRules::BlackOverdue.query_for(product_key).deep_stringify_keys
    rows = NotificationCustomerListService.call(Notification.new(category: "black_overdue", metadata: { "query" => query }))
    return [] if rows.empty?

    cycles = latest_cycles(rows.map { |r| r[:email] }, product_key)
    notes = latest_notes(cycles.values.map(&:id))

    rows.map { |r| cycle = cycles[r[:email]]; r.merge(cycle: cycle, last_note: notes[cycle&.id]) }
        .sort_by { |r| [DONE_STATUSES.include?(r[:cycle]&.follow_up_status) ? 1 : 0, -r[:total_amount].to_i] }
  end

  # 每位客人這個產品「還沒回購」的最新週期優先；沒有就退而求其次拿最新一列。
  def latest_cycles(emails, product_key)
    # 追蹤表用 JourneyProducts 的代號（qingxian／simi），週期表用 crm_products 的代號
    # （cleanse_powder／intimate_powder），要先對應，否則這兩個產品會全部找不到週期。
    cycle_key = NotificationRules::ProductKeyMapping::TRACKING_TO_CRM_PRODUCT_KEY.fetch(product_key, product_key)
    CrmCustomerProductCycle.where(email: emails, product_key: cycle_key).order(cycle_started_at: :desc).to_a
                           .group_by(&:email)
                           .transform_values { |cs| cs.find { |c| c.match_status == "not_yet_repurchased" } || cs.first }
  end

  def latest_notes(cycle_ids)
    return {} if cycle_ids.empty?

    CrmCustomerProductFollowUpEvent.where(cycle_id: cycle_ids).where.not(note: [nil, ""])
                                   .includes(:performed_by).order(performed_at: :desc).to_a
                                   .group_by(&:cycle_id).transform_values(&:first)
  end
end
