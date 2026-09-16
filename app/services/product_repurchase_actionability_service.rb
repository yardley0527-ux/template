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

  # 分層定義（互斥且完備，本商品逾期天數 × 本商品歷史回購次數）：
  #   A級：逾期0～30天 且 過去至少回購2次
  #   B級：(逾期0～30天 且 回購次數<2) 或 (逾期31～90天 且 回購次數≥1)
  #   C級：(逾期31～90天 且 回購次數=0) 或 (逾期91～180天，不限次數)
  #   沉睡：逾期超過180天
  # 任何算得出 overdue_days≥0 且 repurchase_count≥0 的列都必落入以上四層之一
  # （見 classify_tier 的 case 分支覆蓋全部區間，沒有遺漏）。unclassified 只
  # 保留給資料本身異常的防禦性case（remaining_days_sql算不出來、負數逾期天數
  # 混進了overdue scope、回購次數為負等不該發生但要能監控到的情況），不是
  # 規則的正常出口——正常fixture資料的unclassified_count必須是0。
  TIER_A_MAX_DAYS = 30
  TIER_B_MAX_DAYS = 90
  TIER_C_MAX_DAYS = 180
  TIER_A_MIN_REPURCHASES = 2
  TIER_B_MIN_REPURCHASES = 1

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
    # 本產品「累積回購次數」＝這個 identity_key 底下 match_status 不是
    # not_yet_repurchased 的 cycle 列數（每一列代表一次完整的購買週期，
    # matched 代表那次週期真的等到了下一次回購）——用來判斷 A/B/C 分層
    # 門檻裡的「過去至少回購2次」「曾回購過」，不是「該產品的購買總次數」。
    repurchase_counts = CrmCustomerProductCycle.for_product(@key).matched.where(identity_key: identity_keys)
                                                .group(:identity_key).count

    buckets = AGE_BUCKETS.to_h { |label, *_| [label, 0] }
    counters = Hash.new(0)
    tier_counts = Hash.new(0)

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

      tier = classify_tier(overdue_days, repurchase_counts[identity_key].to_i)
      tier_counts[tier] += 1
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
      "actionable_count"              => counters[:actionable],
      "tiers" => {
        "a_tier_count"        => tier_counts[:a],
        "b_tier_count"        => tier_counts[:b],
        "c_tier_count"        => tier_counts[:c],
        "dormant_tier_count"  => tier_counts[:dormant],
        "unclassified_count"  => tier_counts[:unclassified],
        "definition" => "A級：逾期0-#{TIER_A_MAX_DAYS}天且本產品過去至少回購#{TIER_A_MIN_REPURCHASES}次／" \
                         "B級：(逾期0-#{TIER_A_MAX_DAYS}天且回購次數<#{TIER_A_MIN_REPURCHASES})或(逾期#{TIER_A_MAX_DAYS+1}-#{TIER_B_MAX_DAYS}天且回購次數≥#{TIER_B_MIN_REPURCHASES})／" \
                         "C級：(逾期#{TIER_A_MAX_DAYS+1}-#{TIER_B_MAX_DAYS}天且從未回購過)或(逾期#{TIER_B_MAX_DAYS+1}-#{TIER_C_MAX_DAYS}天，不限次數)／" \
                         "沉睡：逾期超過#{TIER_C_MAX_DAYS}天",
        "unclassified_note" => "只有資料異常（算不出逾期天數、逾期天數或回購次數為負、必要欄位缺失）才會落在這裡；" \
                                "正常資料理論上應為0，非0代表資料品質有問題需要排查"
      }
    }
  end

  private

  # A/B/C/沉睡分層——互斥且完備，見上方 TIER_* 常數註解的規則說明。
  # overdue_days/repurchase_count 只要是合理範圍內的數字，一定會落入四層
  # 之一；unclassified 只保留給資料異常（見下方防禦性檢查）。
  def classify_tier(overdue_days, repurchase_count)
    return :unclassified unless overdue_days.is_a?(Numeric) && overdue_days >= 0
    return :unclassified unless repurchase_count.is_a?(Numeric) && repurchase_count >= 0

    case overdue_days
    when 0..TIER_A_MAX_DAYS
      repurchase_count >= TIER_A_MIN_REPURCHASES ? :a : :b
    when (TIER_A_MAX_DAYS + 1)..TIER_B_MAX_DAYS
      repurchase_count >= TIER_B_MIN_REPURCHASES ? :b : :c
    when (TIER_B_MAX_DAYS + 1)..TIER_C_MAX_DAYS
      :c
    else
      :dormant
    end
  end

  def empty_result
    {
      "total_overdue" => 0, "age_buckets" => AGE_BUCKETS.to_h { |l, *_| [l, 0] },
      "reachable_count" => 0, "not_reachable_count" => 0, "already_has_task_count" => 0,
      "contacted_last_30d_count" => 0, "fully_dormant_count" => 0, "single_purchase_only_count" => 0,
      "has_repurchased_before_count" => 0, "in_stock" => @in_stock,
      "max_actionable_overdue_days" => MAX_ACTIONABLE_OVERDUE_DAYS, "actionable_count" => 0,
      "tiers" => { "a_tier_count" => 0, "b_tier_count" => 0, "c_tier_count" => 0, "dormant_tier_count" => 0, "unclassified_count" => 0,
                   "definition" => nil, "unclassified_note" => nil }
    }
  end
end
