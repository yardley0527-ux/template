# frozen_string_literal: true

# 依「首購來源」分群追蹤客人：每個人第一筆已付款訂單決定首購來源
# （產品優先順序同 CustomerPurchaseSummaryRefreshService，PDRN 再拆預購／現貨），
# 之後看回購次數、金額、跨買、卡別變化。
#
# 同一個人：email 與 IG 互相串；黑名單（含同 IG）整個人排除。
# 回購＝首購那天之後「另一天」的任何已付款訂單。
class ProductCohortAnalysis
  WINDOWS = [30, 60, 90].freeze
  LEVELS = %w[一般會員 白卡 銀卡 金卡 黑卡].freeze
  JUNK_IGS = %w[無 沒有 - x 0 na no n/a none nil null].freeze
  OTHER = "其他"

  SERIES = CustomerPurchaseSummaryRefreshService::SERIES_OPTIONS
  SERIES_KEYWORDS = CustomerPurchaseSummaryRefreshService::SERIES_KEYWORDS

  # 跨買用的產品類別（瘦身組合單獨一類，要排在肉鹼／代謝錠前面）
  FAMILIES = [
    ["瘦身組合", /\A肉鹼1代謝錠1/],
    ["PDRN", /PDRN/], ["全能", /全能/], ["代謝錠", /代謝錠/], ["肉鹼", /肉鹼/], ["薑黃", /薑黃/],
    ["清纖粉", /清纖粉/], ["穀胱甘肽", /穀胱甘肽/], ["益生菌", /益生菌/], ["魚油", /魚油/],
    ["蝦紅素", /蝦紅素/], ["維DK鈣", /維D/], ["膠原蛋白", /膠原/], ["冰晶蕃茄", /冰晶/], ["私密粉", /私密粉/], ["美白", /美白/]
  ].freeze

  PERIODS = {
    "" => "全部",
    "2026" => "2026 年首購",
    "2025" => "2025 年首購",
    "2024" => "2024 年首購",
    "180" => "近 180 天首購"
  }.freeze

  # 結果跟今天日期無關（30/60/90 天在 summarize 才算），所以只看訂單有沒有更新
  def self.cache_key
    ["product_cohort_analysis/v1", ShoplineOrder.maximum(:updated_at)&.to_i]
  end

  def self.people
    Rails.cache.fetch(cache_key, expires_in: 7.days) { new.build_people }
  end

  # 匯入訂單後先算好，第一個打開頁面的人不用等
  def self.warm!
    Rails.cache.write(cache_key, new.build_people, expires_in: 7.days)
  end

  def self.sources
    SERIES.flat_map { |s| s == "PDRN" ? ["PDRN 預購", "PDRN 現貨"] : [s] } + [OTHER]
  end

  def self.in_period(people, period)
    case period
    when "2024", "2025", "2026" then people.select { |p| p[:first_date].year == period.to_i }
    when "180" then people.select { |p| p[:first_date] >= Date.current - 180 }
    else people
    end
  end

  def self.summarize(people)
    today = Date.current
    back = people.select { |p| p[:after_days].positive? }
    windows = WINDOWS.to_h do |n|
      eligible = people.select { |p| p[:first_date] <= today - n }
      hit = eligible.count { |p| p[:first_after_date] && p[:first_after_date] <= p[:first_date] + n }
      [n, { eligible: eligible.size, hit: hit }]
    end
    cross = Hash.new { |h, k| h[k] = { people: 0, revenue: 0.0 } }
    people.each do |p|
      p[:cross].each { |f| cross[f][:people] += 1 }
      p[:cross_revenue].each { |f, v| cross[f][:revenue] += v if p[:cross].include?(f) }
    end
    upgrades = people.select { |p| p[:upgraded] }
    {
      total: people.size,
      repurchased: back.size,
      same_again: people.count { |p| p[:same_again] },
      after_amount: back.sum { |p| p[:after_amount] },
      avg_after_days: back.any? ? (back.sum { |p| p[:after_days] }.to_f / back.size).round(1) : 0,
      avg_first_amount: people.any? ? (people.sum { |p| p[:first_amount] } / people.size).round : 0,
      windows: windows,
      cross: cross.sort_by { |_, v| -v[:people] }.to_h,
      upgraded: upgrades.size,
      upgrade_paths: upgrades.group_by { |p| "#{p[:level_at_first]} → #{p[:level_now]}" }.transform_values(&:size).sort_by { |_, v| -v }.to_h
    }
  end

  def build_people
    orders = load_orders
    blacklist_emails = MessageListBuilder.blacklisted_emails.keys.to_set
    blacklist_igs = MessageListBuilder.blacklisted_igs
    customers = ShoplineCustomer.pluck(:id, :email, :full_name, :membership_level, :instagram_account)
                                .index_by { |c| norm_email(c[1]) }

    cluster(orders).filter_map do |os|
      next if os.any? { |o| blacklist_emails.include?(o[:email]) || (o[:ig] && blacklist_igs.include?(o[:ig])) }
      build_person(os, customers)
    end
  end

  private

  # 正式站 DB 做 GROUP BY／排序很慢（4 萬多列要 10 秒以上），直接拉明細回來在 Ruby 分組
  def load_orders
    rows = ShoplineOrder.where(payment_status: "已付款")
                        .where.not(order_number: [nil, ""]).where.not(email: [nil, ""]).where.not(order_date: nil)
                        .pluck(:order_number, :order_date, :email, :instagram_account, :membership_level,
                               :total_amount, :product_name, :quantity, :checkout_amount)
    rows.group_by(&:first).map do |number, rs|
      lines = rs.map { |r| { name: r[6].to_s, qty: r[7].to_i.nonzero? || 1, price: r[8].to_f } }
      amount = rs.map { |r| r[5].to_f }.max
      amount = lines.sum { |l| l[:price] * l[:qty] } if amount.zero?
      { number: number, date: rs.map { |r| r[1] }.min.to_date, email: norm_email(rs.first[2]),
        ig: rs.filter_map { |r| norm_ig(r[3]) }.first, level: rs.filter_map { |r| r[4].presence }.first,
        amount: amount, lines: lines }
    end
  end

  def cluster(orders)
    parent = {}
    find = lambda do |x|
      parent[x] ||= x
      parent[x] = find.call(parent[x]) unless parent[x] == x
      parent[x]
    end
    orders.each do |o|
      a = find.call("e:#{o[:email]}")
      parent[a] = find.call("i:#{o[:ig]}") if o[:ig]
    end
    orders.group_by { |o| find.call("e:#{o[:email]}") }.values.map { |os| os.sort_by { |o| [o[:date], o[:number]] } }
  end

  def build_person(os, customers)
    first = os.first
    source = source_of(first)
    source_family = source.start_with?("PDRN") ? "PDRN" : source
    after = os.select { |o| o[:date] > first[:date] }
    paid_after = after.flat_map { |o| o[:lines] }.select { |l| l[:price].positive? }
    after_families = paid_after.map { |l| family(l[:name]) }.uniq
    emails = os.map { |o| o[:email] }.uniq
    found = ([os.last[:email]] + emails.reverse).uniq.filter_map { |e| customers[e] }
    level_at_first = first[:level].presence || "一般會員"
    level_now = found.map { |c| c[3].presence || "一般會員" }.max_by { |l| LEVELS.index(l) || 0 } || level_at_first
    {
      source: source,
      customer_id: found.first&.first,
      name: found.map { |c| c[2].presence }.compact.first || os.last[:email].to_s.split("@").first,
      ig: os.map { |o| o[:ig] }.compact.last || found.filter_map { |c| norm_ig(c[4]) }.first,
      first_date: first[:date],
      first_amount: first[:amount].round,
      first_items: item_names(first),
      after_days: after.map { |o| o[:date] }.uniq.size,
      after_amount: after.sum { |o| o[:amount] }.round,
      first_after_date: after.first&.dig(:date),
      same_again: after_families.include?(source_family),
      cross: after_families - [source_family, "其他"],
      cross_revenue: paid_after.group_by { |l| family(l[:name]) }.transform_values { |ls| ls.sum { |l| l[:price] * l[:qty] } },
      last_order_date: os.last[:date],
      last_items: item_names(os.last),
      level_at_first: level_at_first,
      level_now: level_now,
      upgraded: (LEVELS.index(level_now) || 0) > (LEVELS.index(level_at_first) || 0)
    }
  end

  # 首購來源：依 SERIES 優先順序挑第一筆訂單裡的產品（跟客人資料庫的首購來源一致）
  def source_of(order)
    names = order[:lines].map { |l| l[:name] }
    series = SERIES.find { |s| (SERIES_KEYWORDS[s] || [s]).any? { |kw| names.any? { |n| n.include?(kw) } } }
    return OTHER unless series
    return series unless series == "PDRN"
    names.any? { |n| n.start_with?("預購") && n.include?("PDRN") } ? "PDRN 預購" : "PDRN 現貨"
  end

  def item_names(order)
    order[:lines].select { |l| l[:price].positive? }.map { |l| l[:name] }.uniq.join("、")
  end

  def family(name)
    FAMILIES.find { |_, re| name.match?(re) }&.first || "其他"
  end

  def norm_email(e)
    e.to_s.strip.downcase.presence
  end

  def norm_ig(ig)
    v = MessageListBuilder.normalize_ig(ig)
    v if v && v.length >= 3 && !JUNK_IGS.include?(v)
  end
end
