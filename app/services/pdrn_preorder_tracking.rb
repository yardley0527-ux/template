# frozen_string_literal: true

# PDRN 預購客追蹤：所有買過「預購-PDRN」（已付款、結帳價 > 0）的客人，
# 看他們預購之後有沒有再買、買了什麼、卡別有沒有升級。
#
# 同一個人：email 與 IG 互相串（同 IG 的不同 email 算同一人），IG 佔位字不算。
# 黑名單（brand_ambassador_blacklisted / blacklisted，含同 IG）整個人排除。
# 回購：預購那天之後「另一天」的任何已付款訂單（包含再加購預購）。
class PdrnPreorderTracking
  PREORDER_PATTERN = "預購-PDRN%"
  LEVELS = %w[一般會員 白卡 銀卡 金卡 黑卡].freeze
  WINDOWS = [30, 60, 90].freeze
  JUNK_IGS = %w[無 沒有 - x 0 na no n/a none nil null].freeze

  # 品名 → 產品類別（瘦身組合要排在肉鹼／代謝錠前面先比對）
  FAMILIES = [
    ["瘦身組合", /\A肉鹼1代謝錠1/],
    ["PDRN", /PDRN/], ["全能", /全能/], ["代謝錠", /代謝錠/], ["肉鹼", /肉鹼/], ["薑黃", /薑黃/],
    ["清纖粉", /清纖粉/], ["穀胱甘肽", /穀胱甘肽/], ["益生菌", /益生菌/], ["魚油", /魚油/],
    ["蝦紅素", /蝦紅素/], ["維DK鈣", /維D/], ["膠原蛋白", /膠原/], ["冰晶蕃茄", /冰晶/], ["私密粉", /私密粉/]
  ].freeze

  Order = Struct.new(:number, :date, :email, :ig, :level, :amount, :lines, keyword_init: true) do
    def preorder?
      lines.any? { |l| l[:name].start_with?("預購-PDRN") && l[:price].positive? }
    end
  end

  def self.call
    Rails.cache.fetch(["pdrn_preorder_tracking/v1", Date.current, ShoplineOrder.maximum(:updated_at)], expires_in: 12.hours) do
      new.call
    end
  end

  def call
    orders = load_orders
    clusters = cluster(orders)
    blacklist_emails = MessageListBuilder.blacklisted_emails.keys.to_set
    blacklist_igs = MessageListBuilder.blacklisted_igs

    people = []
    excluded = []
    clusters.each do |os|
      next unless os.any?(&:preorder?)
      if os.any? { |o| blacklist_emails.include?(o.email) || (o.ig && blacklist_igs.include?(o.ig)) }
        excluded << os
        next
      end
      people << build_person(os)
    end
    attach_customers(people)
    excluded_names = excluded.map { |os| customer_name_for(os) }

    { people: people, summary: summarize(people), excluded_names: excluded_names, data_until: orders.map(&:date).max }
  end

  private

  def load_orders
    seed = ShoplineOrder.where(payment_status: "已付款").where("product_name LIKE ?", PREORDER_PATTERN)
                        .where("checkout_amount > 0").pluck(:email, :instagram_account)
    emails = seed.map { |e, _| norm_email(e) }.compact.uniq
    igs = seed.map { |_, ig| norm_ig(ig) }.compact.uniq
    # 往外擴兩層：同 IG 的其他 email、那些 email 的其他 IG
    2.times do
      rows = ShoplineOrder.where(payment_status: "已付款")
                          .where("LOWER(TRIM(email)) IN (:e) OR LOWER(TRIM(instagram_account)) IN (:i)", e: emails, i: igs.presence || [""])
                          .distinct.pluck(:email, :instagram_account)
      emails |= rows.map { |e, _| norm_email(e) }.compact
      igs |= rows.map { |_, ig| norm_ig(ig) }.compact
    end

    ShoplineOrder.where(payment_status: "已付款").where("LOWER(TRIM(email)) IN (?)", emails)
                 .order(:order_number, :id)
                 .pluck(:order_number, :order_date, :email, :instagram_account, :membership_level, :total_amount, :product_name, :quantity, :checkout_amount)
                 .group_by(&:first)
                 .map do |number, rows|
                   lines = rows.map { |r| { name: r[6].to_s, qty: r[7].to_i.nonzero? || 1, price: r[8].to_f } }
                   total = rows.map { |r| r[5].to_f }.max
                   total = lines.sum { |l| l[:price] * l[:qty] } if total.zero?
                   Order.new(number: number, date: rows.first[1].to_date, email: norm_email(rows.first[2]),
                             ig: rows.map { |r| norm_ig(r[3]) }.compact.first, level: rows.map { |r| r[4].presence }.compact.first,
                             amount: total, lines: lines)
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
      a = find.call("e:#{o.email}")
      parent[a] = find.call("i:#{o.ig}") if o.ig
    end
    orders.group_by { |o| find.call("e:#{o.email}") }.values.map { |os| os.sort_by { |o| [o.date, o.number] } }
  end

  def build_person(os)
    pre = os.select(&:preorder?)
    first_pre = pre.first
    after = os.select { |o| o.date > first_pre.date }
    cross = after.flat_map { |o| o.lines.select { |l| l[:price].positive? }.map { |l| family(l[:name]) } }.uniq - ["PDRN"]
    level_at_pre = first_pre.level.presence || "一般會員"
    {
      emails: os.map(&:email).uniq,
      latest_email: os.last.email,
      ig: os.map(&:ig).compact.last,
      new_customer: os.first.preorder?,
      first_pre_date: first_pre.date,
      pre_dates: pre.map(&:date).uniq,
      pre_bottles: pre.sum { |o| o.lines.select { |l| l[:name].start_with?("預購-PDRN") && l[:price].positive? }.sum { |l| bottles(l[:name]) * l[:qty] } },
      pre_amount: pre.sum(&:amount).round,
      after_days: after.map(&:date).uniq.size,
      after_amount: after.sum(&:amount).round,
      first_after_date: after.first&.date,
      cross: cross,
      cross_revenue: after.flat_map(&:lines).select { |l| l[:price].positive? }
                          .group_by { |l| family(l[:name]) }.transform_values { |ls| ls.sum { |l| l[:price] * l[:qty] } },
      last_order_date: os.last.date,
      last_items: os.last.lines.select { |l| l[:price].positive? }.map { |l| l[:name] }.uniq.join("、"),
      level_at_pre: level_at_pre
    }
  end

  def attach_customers(people)
    emails = people.flat_map { |p| p[:emails] }
    customers = ShoplineCustomer.where("LOWER(TRIM(email)) IN (?)", emails)
                                .pluck(:id, :email, :full_name, :membership_level, :instagram_account)
                                .index_by { |c| norm_email(c[1]) }
    people.each do |p|
      found = ([p[:latest_email]] + p[:emails].reverse).uniq.filter_map { |e| customers[e] }
      main = found.first
      p[:customer_id] = main&.first
      p[:name] = found.map { |c| c[2].presence }.compact.first || p[:latest_email].to_s.split("@").first
      p[:ig] ||= found.filter_map { |c| norm_ig(c[4]) }.first
      p[:level_now] = found.map { |c| c[3].presence || "一般會員" }.max_by { |l| LEVELS.index(l) || 0 } || p[:level_at_pre]
      p[:upgraded] = (LEVELS.index(p[:level_now]) || 0) > (LEVELS.index(p[:level_at_pre]) || 0)
    end
  end

  def customer_name_for(os)
    ShoplineCustomer.where("LOWER(TRIM(email)) IN (?)", os.map(&:email).uniq).where.not(full_name: [nil, ""]).pick(:full_name) || os.first.email
  end

  def summarize(people)
    today = Date.current
    repurchased = people.select { |p| p[:after_days].positive? }
    windows = WINDOWS.to_h do |n|
      eligible = people.select { |p| p[:first_pre_date] <= today - n }
      hit = eligible.count { |p| p[:first_after_date] && p[:first_after_date] <= p[:first_pre_date] + n }
      [n, { eligible: eligible.size, hit: hit }]
    end
    cross = Hash.new { |h, k| h[k] = { people: 0, revenue: 0.0 } }
    people.each do |p|
      p[:cross].each { |f| cross[f][:people] += 1 }
      p[:cross_revenue].each { |f, v| cross[f][:revenue] += v unless f == "PDRN" }
    end
    upgrades = people.select { |p| p[:upgraded] }
    {
      total: people.size,
      new_customers: people.count { |p| p[:new_customer] },
      repurchased: repurchased.size,
      after_amount: repurchased.sum { |p| p[:after_amount] },
      avg_after_days: repurchased.any? ? (repurchased.sum { |p| p[:after_days] }.to_f / repurchased.size).round(1) : 0,
      windows: windows,
      cross: cross.sort_by { |_, v| -v[:people] }.to_h,
      upgraded: upgrades.size,
      upgrade_paths: upgrades.group_by { |p| "#{p[:level_at_pre]} → #{p[:level_now]}" }.transform_values(&:size).sort_by { |_, v| -v }.to_h
    }
  end

  def family(name)
    FAMILIES.find { |_, re| name.match?(re) }&.first || "其他"
  end

  def bottles(name)
    m = name.match(/(\d+)(?:送(\d+))?\z/)
    m ? m[1].to_i + m[2].to_i : 1
  end

  def norm_email(e)
    e.to_s.strip.downcase.presence
  end

  def norm_ig(ig)
    v = MessageListBuilder.normalize_ig(ig)
    v if v && v.length >= 3 && !JUNK_IGS.include?(v)
  end
end
