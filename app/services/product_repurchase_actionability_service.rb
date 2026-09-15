# frozen_string_literal: true

# 把「逾期未回購」從一個累積總數拆成：逾期區間分佈 ＋ 排除掉不該再打擾/已在
# 處理中/長期沉睡到追不回來的人之後，本週真正值得優先聯繫的人數。
#
# 累積逾期總人數（例如代謝錠4千多人）不是「本週可以聯繫的名單」——這支
# service 只回答「這批人裡面，扣掉已經有客服任務、最近30天已聯繫過、逾期
# 超過半年（公司既有 SOP 慣例，見 message-list-cohort-logic 記憶：逾期名單
# 上限抓180天）、缺貨中商品、以及沒有聯絡方式的人之後，還剩多少人」。
class ProductRepurchaseActionabilityService
  AGE_BUCKETS = [
    ["1-30",    1,   30],
    ["31-60",   31,  60],
    ["61-90",   61,  90],
    ["91-120",  91,  120],
    ["121-180", 121, 180],
    ["181-365", 181, 365],
    ["366+",    366, nil]
  ].freeze

  CONTACTED_RECENTLY_DAYS     = 30
  MAX_ACTIONABLE_OVERDUE_DAYS = 180
  DORMANT_ANY_PRODUCT_DAYS    = 180

  def self.call(product_key:, reference_date:, availability_status:)
    new(product_key, reference_date, availability_status).call
  end

  def initialize(product_key, reference_date, availability_status)
    @key = product_key
    @ref = reference_date
    @in_stock = %w[in_stock low_stock preorder].include?(availability_status)
  end

  def call
    cycles = CrmCustomerProductCycle.active_as_of(@ref).for_product(@key)
    # with_status_filter(..., "overdue") 本身就只挑 follow_up_status IS NULL
    # 的列（跟回購追蹤 Dashboard 同一份定義：一旦客服手動標成 waiting_reply/
    # rescheduled/paused，就改算在那個狀態底下，不再算「逾期未回購」）——所以
    # 這個 scope 裡永遠不會出現「已有客服任務」的人，already_has_task_count
    # 結構上恆為0，這是符合既有定義的正確行為，不是漏算。
    overdue_scope = CrmCustomerProductCycle.with_status_filter(cycles, "overdue", reference_date: @ref)
    remaining_sql = CrmCustomerProductCycle.remaining_days_sql(reference_date: @ref)

    rows = overdue_scope.pluck(:email, :identity_key, Arel.sql("(#{remaining_sql})"), :follow_up_status, :last_contacted_at)
    return empty_result if rows.empty?

    emails = rows.map { |r| r[0] }.uniq
    summaries = CustomerPurchaseSummary.where(email: emails)
                                        .pluck(:email, :purchase_count, :last_order_date, :line_bound, :mobile_phone)
                                        .to_h { |email, cnt, last_date, line, phone| [email, { count: cnt, last_date: last_date&.to_date, line: line, phone: phone }] }

    identity_keys = rows.map { |r| r[1] }.uniq
    ever_repurchased = CrmCustomerProductCycle.for_product(@key).matched.where(identity_key: identity_keys)
                                               .distinct.pluck(:identity_key).to_set

    buckets = AGE_BUCKETS.to_h { |label, *_| [label, 0] }
    counters = Hash.new(0)

    rows.each do |email, identity_key, remaining, follow_up_status, last_contacted_at|
      overdue_days = -remaining.to_i
      bucket = AGE_BUCKETS.find { |_, lo, hi| overdue_days >= lo && (hi.nil? || overdue_days <= hi) }
      buckets[bucket.first] += 1 if bucket

      summary = summaries[email]
      dormant = summary.nil? || summary[:last_date].nil? || (@ref - summary[:last_date]) > DORMANT_ANY_PRODUCT_DAYS
      counters[:fully_dormant] += 1 if dormant
      counters[:single_purchase_only] += 1 if summary && summary[:count].to_i <= 1
      counters[:has_repurchased_before] += 1 if ever_repurchased.include?(identity_key)

      has_active_task = follow_up_status.present? && follow_up_status != "repurchased"
      counters[:already_has_task] += 1 if has_active_task
      recently_contacted = last_contacted_at.present? && (@ref - last_contacted_at.to_date) <= CONTACTED_RECENTLY_DAYS
      counters[:contacted_last_30d] += 1 if recently_contacted
      contactable = summary && (summary[:line] || summary[:phone].present?)
      counters[:reachable] += 1 if contactable

      counters[:actionable] += 1 if @in_stock && overdue_days <= MAX_ACTIONABLE_OVERDUE_DAYS &&
                                     !has_active_task && !recently_contacted && contactable
    end

    {
      "total_overdue"                => rows.size,
      "age_buckets"                  => buckets,
      "reachable_count"               => counters[:reachable],
      "not_reachable_count"           => rows.size - counters[:reachable],
      "already_has_task_count"        => counters[:already_has_task],
      "contacted_last_30d_count"      => counters[:contacted_last_30d],
      "fully_dormant_count"           => counters[:fully_dormant],
      "single_purchase_only_count"    => counters[:single_purchase_only],
      "has_repurchased_before_count"  => counters[:has_repurchased_before],
      "in_stock"                      => @in_stock,
      "max_actionable_overdue_days"   => MAX_ACTIONABLE_OVERDUE_DAYS,
      "actionable_count"              => counters[:actionable]
    }
  end

  private

  def empty_result
    {
      "total_overdue" => 0, "age_buckets" => AGE_BUCKETS.to_h { |l, *_| [l, 0] },
      "reachable_count" => 0, "not_reachable_count" => 0, "already_has_task_count" => 0,
      "contacted_last_30d_count" => 0, "fully_dormant_count" => 0, "single_purchase_only_count" => 0,
      "has_repurchased_before_count" => 0, "in_stock" => @in_stock,
      "max_actionable_overdue_days" => MAX_ACTIONABLE_OVERDUE_DAYS, "actionable_count" => 0
    }
  end
end
