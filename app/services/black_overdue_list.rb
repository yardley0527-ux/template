# frozen_string_literal: true

# 「客戶商機」分頁的黑卡逾期未回購名單：依產品分組，一人一列，讓老闆直接在畫面上維護
# （記聯絡狀態、寫備註），不用下載表格。
#
# 名單本身由 NotificationCustomerListService 即時算（黑卡、逾期 1–60 天、已回購就不出現、
# 累積消費高的排前面）；維護狀態沿用回購追蹤的 CrmCustomerProductCycle／
# CrmCustomerProductFollowUpEvent，跟回購追蹤 Dashboard 是同一份資料，不另開一套。
class BlackOverdueList
  # note：這個產品沒有名單時的補充說明（例如波段補貨不列逾期、缺貨中）。
  Group = Struct.new(:product_key, :label, :rows, :note, keyword_init: true)

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

  # 每個追蹤中的產品都回傳一組；目前沒有黑卡逾期的產品 rows 是空的（畫面寫「尚未有名單」），
  # 有名單的排前面、沒名單的排後面。
  def call
    eligible = NotificationRules::BlackOverdue.eligible_product_keys
    groups = JourneyProducts::PRODUCTS.keys.map do |key|
      label = JourneyProducts::PRODUCTS.dig(key, :label) || key
      if eligible.include?(key)
        Group.new(product_key: key, label: label, rows: rows_for(key))
      else
        Group.new(product_key: key, label: label, rows: [], note: unavailable_note(key, label))
      end
    end
    groups.partition { |g| g.rows.any? }.flatten(1)
  end

  private

  def unavailable_note(product_key, label)
    if NotificationRules::BlackOverdue::EXCLUDED_PRODUCTS.include?(product_key)
      "#{label}屬波段補貨，固定天數的逾期判斷不成立，所以不列逾期名單"
    else
      "#{label}目前缺貨或停售，暫不列名單"
    end
  end

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
