# frozen_string_literal: true

# 把 AI 產出的「目標客群條件」(target_query) 轉成實際 CRM 查詢——AI 只能提出
# 條件描述，不可以自己生成 customer id（CLAUDE 指示明確要求）。只支援少數
# 已有可靠資料來源的條件類型；其餘一律回傳 unresolved（前端顯示「需人工建立
# 名單」，不會假裝算得出人數)。
#
# 新增類型時：一定要接到既有的資料表/service（CrmCustomerProductCycle、
# CustomerPurchaseSummary 等），不要另外發明一套判斷邏輯。
class WeeklyBriefingTodoTargetResolver
  UNRESOLVED = { resolved: false, count: nil, emails: [] }.freeze

  def self.call(target_query)
    new(target_query).call
  end

  def initialize(target_query)
    @type = target_query&.dig("type")
    @params = target_query || {}
  end

  def call
    case @type
    when "product_overdue" then product_overdue
    when "product_due_soon" then product_due_soon
    when "dormant_member" then dormant_member
    else UNRESOLVED
    end
  end

  private

  # { type: "product_overdue", product_key: "metabolism", min_days: 1, max_days: 30 }
  def product_overdue
    key = @params["product_key"].presence
    return UNRESOLVED unless key && CrmProduct.exists?(key: key)

    min_days = @params["min_days"].to_i
    min_days = 1 if min_days <= 0
    max_days = @params["max_days"].presence&.to_i

    scope = CrmCustomerProductCycle.active_follow_up.for_product(key)
    remaining = CrmCustomerProductCycle.remaining_days_sql
    scope = scope.where(follow_up_status: nil).where("(#{remaining}) <= ?", -min_days)
    scope = scope.where("(#{remaining}) >= ?", -max_days) if max_days.present?

    build_result(scope)
  end

  # { type: "product_due_soon", product_key: "turmeric", within_days: 7 }
  def product_due_soon
    key = @params["product_key"].presence
    return UNRESOLVED unless key && CrmProduct.exists?(key: key)

    within_days = @params["within_days"].presence&.to_i || CrmCustomerProductCycle::DUE_SOON_DAYS

    scope = CrmCustomerProductCycle.with_status_filter(
      CrmCustomerProductCycle.active_follow_up.for_product(key), "due_soon"
    )
    scope = scope.where("(#{CrmCustomerProductCycle.remaining_days_sql}) <= ?", within_days)

    build_result(scope)
  end

  # { type: "dormant_member", level: "金卡", min_silent_days: 60 }
  def dormant_member
    level = @params["level"].presence
    return UNRESOLVED unless level && MembershipLevels::TARGET_MEMBERSHIPS.include?(level)

    min_silent_days = @params["min_silent_days"].presence&.to_i || WeeklyMetricsService::ACTIVE_MEMBER_WINDOW_DAYS
    cutoff = Date.current - min_silent_days

    emails = ShoplineCustomer.where(membership_level: level).where.not(email: [nil, ""]).pluck(:email)
    return UNRESOLVED if emails.empty?

    last_orders = CustomerPurchaseSummary.where(email: emails).group(:email).maximum(:last_order_date)
    target_emails = emails.select { |e| last_orders[e].present? && last_orders[e].to_date < cutoff }

    { resolved: true, count: target_emails.size, emails: target_emails.first(500) }
  end

  def build_result(cycle_scope)
    rows = cycle_scope.distinct.pluck(:email)
    { resolved: true, count: rows.size, emails: rows.first(500) }
  end
end
