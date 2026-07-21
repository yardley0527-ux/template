# frozen_string_literal: true

# 方案 B PR4：直播策略報表改讀 Livestream／PR2 統計快取，不再以 ALL_EVENTS
# （livestream_analysis_controller.rb 的手抄常數）為分析來源。四個頁籤：
# 總覽／出席與回流（併入舊「品牌之夜總覽」）／來源回購／歸因窗。
class LivestreamStrategyController < ApplicationController
  include JourneyProducts
  include MembershipLevels

  before_action :set_product, only: :sources

  LEVELS = %w[黑卡 金卡 銀卡 白卡].freeze

  def index
    @events = Livestream.where("date <= ?", Date.current).reorder(:date).to_a
    return if @events.empty?

    @event_hashes = @events.map { |ls| event_hash(ls) }

    @years = [2024, 2025, 2026].map { |y| year_summary(y, @event_hashes.select { |e| e[:year] == y }) }

    @level_by_year = LEVELS.map do |level|
      avg = ->(y) { avg_attendance(@event_hashes.select { |e| e[:year] == y }, level) }
      { level: level, avg_2024: avg.call(2024), avg_2025: avg.call(2025), avg_2026: avg.call(2026),
        trend_25: trend(avg.call(2024), avg.call(2025)), trend_26: trend(avg.call(2025), avg.call(2026)) }
    end

    @top_revenue    = @event_hashes.select { |e| e[:revenue] > 0 }.sort_by { |e| -e[:revenue] }.first(10)
    @top_attendance = @event_hashes.sort_by { |e| -e[:levels].values.sum { |d| d[:n] } }.first(10)

    @monthly_stats = build_monthly_stats(@event_hashes)
    @series_stats  = build_series_stats(@event_hashes)

    @black_total = ShoplineCustomer.where(membership_level: "黑卡").count
    @black_by_year = [2024, 2025, 2026].map do |y|
      evts = @event_hashes.select { |e| e[:year] == y }
      avg_n = evts.empty? ? 0 : (evts.sum { |e| e[:levels]["黑卡"][:n] }.to_f / evts.size).round(1)
      rate  = @black_total.positive? ? (avg_n / @black_total * 100).round(1) : 0
      { year: y, avg_n: avg_n, rate: rate, events: evts.size }
    end

    @gap_buckets, @best_gap_label = build_gap_buckets(@event_hashes)
    @summaries = build_summaries
  end

  # 出席與回流：不分產品，全部場次的推定歸因買家（原「品牌之夜總覽」內容）。
  def attendance
    @events_data = Livestream.where("date <= ?", Date.current).reorder(:date).map do |ls|
      attribution = LivestreamAttribution.new(ls)
      emails = attribution.order_rows.filter_map { |r| r[:email] }.uniq
      { livestream: ls, date: ls.date, year: ls.date.year, label: ls.date.strftime("%-m/%-d"), db_emails: emails }
    end
    return if @events_data.empty?

    selected_date = begin
      params[:event].presence && Date.parse(params[:event])
    rescue ArgumentError, TypeError
      nil
    end
    @selected = @events_data.find { |e| e[:date] == selected_date } || @events_data.last
    selected_idx = @events_data.index(@selected)

    events_up_to = @events_data[0..selected_idx]
    @return_rates = []
    events_up_to.each_cons(2) do |prev, curr|
      next if prev[:db_emails].empty? || curr[:db_emails].empty?

      overlap = (prev[:db_emails] & curr[:db_emails]).size
      @return_rates << { from: "#{prev[:year]}/#{prev[:label]}", to: "#{curr[:year]}/#{curr[:label]}",
                         count: overlap, from_total: prev[:db_emails].size, rate: pct(overlap, prev[:db_emails].size) }
    end

    db_events = events_up_to.select { |e| e[:db_emails].any? }

    if db_events.size >= 2
      lookback = db_events[-[4, db_events.size].min..-2]
      prev_emails = lookback.flat_map { |e| e[:db_emails] }.uniq
      missing_emails = prev_emails - db_events.last[:db_emails]
      customers_map = ShoplineCustomer.where(email: missing_emails).index_by(&:email)
      @missing_customers = missing_emails.filter_map do |email|
        c = customers_map[email]
        next unless c

        appeared_in = lookback.select { |e| e[:db_emails].include?(email) }.map { |e| "#{e[:year]}/#{e[:label]}" }
        { customer: c, appeared_in: appeared_in, appeared_count: appeared_in.size }
      end.sort_by { |r| [-MEMBERSHIP_RANK.fetch(r[:customer].membership_level, 0), -r[:appeared_count], -r[:customer].total_amount.to_f] }
    else
      @missing_customers = []
    end

    if db_events.size >= 3
      last3 = db_events.last(3)
      loyal_3_emails = last3.map { |e| e[:db_emails] }.reduce(:&)
      loyal_2_emails = last3.combination(2).flat_map { |a, b| a[:db_emails] & b[:db_emails] }.uniq - loyal_3_emails
      @loyal_3_customers = build_loyal_customers(loyal_3_emails, last3)
      @loyal_2_customers = build_loyal_customers(loyal_2_emails, last3)
    else
      @loyal_3_customers = []
      @loyal_2_customers = []
    end

    @level_totals = TARGET_MEMBERSHIPS.index_with { |level| ShoplineCustomer.where(membership_level: level).count }
    build_attendance_insights
  end

  # 直播來源分析（原 CRM 的 /crm/analytics/broadcasts）：單一產品視角，走
  # ProductNameResolver（不再用 @product[:sql] 的舊式 LIKE）。
  #
  # 效能筆記：原本每場的「窗口內買家 email」被查兩次（一次算全體
  # all_event_emails、一次算本場 buyer_emails），場次數 O(events) 下查詢數
  # 直接乘以二；且每場的營收又各自對該場 order_number 集合下一次
  # IN(...)+GROUP BY 查詢，IN 值多時單條查詢在 DB 端變慢。改成：每場只查
  # 一次窗口內的 email+order_number（兩處重用）＋全部場次的營收合併成一次
  # IN(...) 查詢，迴圈內只查表不再下 SQL。正式站 omnipotent 10 場實測
  # 64→14 條查詢、12.5s→2.3s。
  def sources
    events = Livestream.where("date <= ? AND product_keys @> ARRAY[?]::varchar[]", Date.current, @product_key).reorder(:date).to_a

    event_window_rows = events.index_with do |ls|
      range = LivestreamAttribution.window_range(ls.date, ls.window_days)
      ProductNameResolver.orders_for(@product_key).where(order_date: range).where.not(email: [nil, ""])
                          .distinct.pluck(:email, :order_number)
    end

    all_event_emails = event_window_rows.values.flat_map { |rows| rows.map(&:first) }.uniq

    all_later_orders = Hash.new { |h, k| h[k] = [] }
    if all_event_emails.any?
      ProductNameResolver.orders_for(@product_key).where(email: all_event_emails)
                          .order(:email, :order_date).pluck(:email, :order_date, :order_number)
                          .each { |em, od, on_| all_later_orders[em] << { date: od.to_date, order_number: on_ } }
    end

    all_order_nums = event_window_rows.values.flat_map { |rows| rows.map(&:last) }.uniq.compact
    revenue_by_order_number = if all_order_nums.any?
      ShoplineOrder.where(order_number: all_order_nums).group(:order_number)
                   .pluck(:order_number, Arel.sql("COALESCE(MAX(NULLIF(total_amount,0)), SUM(COALESCE(checkout_amount,0)))"))
                   .to_h { |num, amt| [num, amt.to_f] }
    else
      {}
    end

    @event_stats = events.filter_map do |ls|
      range = LivestreamAttribution.window_range(ls.date, ls.window_days)
      window_end = range.end
      rows = event_window_rows[ls]
      buyer_emails = rows.map(&:first).uniq
      next if buyer_emails.empty?

      order_nums = rows.map(&:last).uniq.compact
      event_revenue = order_nums.sum { |num| revenue_by_order_number[num] || 0 }.round
      repurchased_emails = buyer_emails.select { |em| all_later_orders[em].any? { |o| o[:date] >= window_end.to_date } }

      { label: ls.date.strftime("%Y/%-m/%-d"), date: ls.date, note: ls.title,
        buyers: buyer_emails.size, revenue: event_revenue,
        avg_value: buyer_emails.size.positive? ? (event_revenue.to_f / buyer_emails.size).round : 0,
        repurchased: repurchased_emails.size,
        repurchase_rate: buyer_emails.size.positive? ? (repurchased_emails.size.to_f / buyer_emails.size * 100).round(1) : 0 }
    end.sort_by { |e| -e[:date].to_time.to_i }
  end

  # 歸因窗：D0/D+1/D+3/D+7 比較＋重疊歸因警告。
  #
  # 效能筆記：直接對每場 × 每個比較窗口呼叫 LivestreamAttribution（PR2 的
  # 單場查詢物件）會是 45 場 × 4 窗口 × 2 條 SQL（order_rows + new_buyers）
  # = 360 條查詢——正式站量測到單頁 361 條、42.9 秒。改成整頁只掃描一次
  # 「全部場次涵蓋的最大時間範圍」訂單＋一次全域客戶首購日，其餘在記憶體
  # 中依場次/窗口切分，把查詢數從 O(events×windows) 降到 O(1)（實測 4 條）。
  # 正確性由 test/services/livestream_strategy_windows_equivalence_test.rb
  # 逐場逐窗口比對本方法與 LivestreamAttribution.window_comparison 的結果
  # 完全一致來保證（換算法不能換出不一樣的數字）。
  def windows
    @events = Livestream.where("date <= ?", Date.current).reorder(:date).to_a
    @window_comparisons = self.class.batch_window_comparisons(@events)

    dates = @events.map(&:date)
    @overlap_counts = [0, 1, 3, 7].index_with do |w|
      dates.each_cons(2).count { |a, b| (b - a).to_i <= w }
    end
  end

  def self.batch_window_comparisons(events)
    return [] if events.empty?

    max_window = LivestreamAttribution::DEFAULT_COMPARISON_WINDOWS.max
    zone = ActiveSupport::TimeZone[LivestreamAttribution::TAIPEI_ZONE]
    overall_start = zone.local(events.first.date.year, events.first.date.month, events.first.date.day)
    overall_end   = zone.local(events.last.date.year, events.last.date.month, events.last.date.day) + (max_window + 1).days

    rows = ShoplineOrder.where(order_date: overall_start...overall_end)
                        .where.not(order_number: [nil, ""])
                        .group("shopline_orders.order_number")
                        .pluck(
                          Arel.sql("shopline_orders.order_number"),
                          Arel.sql("MIN(shopline_orders.email) AS email"),
                          Arel.sql("MIN(shopline_orders.order_date) AS order_date"),
                          Arel.sql("(#{ShoplineOrder::TOTAL_SQL}) AS amount")
                        ).map { |on_, email, date, amount| { email: email.presence, time: date, amount: amount.to_d } }

    all_emails = rows.filter_map { |r| r[:email] }.uniq
    first_order_dates = all_emails.any? ? ShoplineOrder.where(email: all_emails).group(:email).minimum(:order_date) : {}

    events.map do |ls|
      comparison = LivestreamAttribution::DEFAULT_COMPARISON_WINDOWS.map do |w|
        range = LivestreamAttribution.window_range(ls.date, w)
        window_rows = rows.select { |r| r[:time] && range.cover?(r[:time]) }
        identified = window_rows.filter_map { |r| r[:email] }.uniq
        new_buyers = identified.count { |email| (first = first_order_dates[email]) && first.to_date >= ls.date }
        {
          window_days: w,
          orders: window_rows.size,
          revenue: window_rows.sum { |r| r[:amount] },
          buyers: identified.size,
          new_buyers: new_buyers,
          unidentified_orders: window_rows.count { |r| r[:email].blank? }
        }
      end
      { livestream: ls, comparison: comparison }
    end
  end

  private

  def set_product
    key          = params[:product].presence || DEFAULT_PRODUCT_KEY
    @product     = PRODUCTS[key] || PRODUCTS[DEFAULT_PRODUCT_KEY]
    @product_key = @product[:key]
    @all_products = PRODUCTS.values
  end

  # ALL_EVENTS 相容的 hash 形狀（date/label/year/note/orders/revenue/levels），
  # 讓既有 index.html.erb 幾乎不用改；額外附 reported_orders/reported_revenue／
  # product_keys 供「歷史登記與推定檔期並列」「系列比較」使用。
  def event_hash(ls)
    {
      date: ls.date, label: ls.date.strftime("%-m/%-d"), year: ls.date.year,
      note: ls.title.presence || ls.product_keys.map { |k| product_label(k) }.compact.join("、"),
      orders: ls.total_orders, revenue: ls.total_revenue.to_i,
      reported_orders: ls.reported_orders, reported_revenue: ls.reported_revenue&.to_i,
      product_keys: ls.product_keys,
      levels: MembershipLevels::LEVEL_KEYS.each_with_object({}) { |(name, key), h| h[name] = { n: ls.public_send(:"level_#{key}_count"), amt: ls.public_send(:"level_#{key}_amount") } }
    }
  end

  def product_label(key)
    @product_label_cache ||= CrmProduct.pluck(:key, :label).to_h
    @product_label_cache[key]
  end

  def year_summary(year, events)
    rev_events = events.select { |e| e[:revenue] > 0 }
    total_rev = rev_events.sum { |e| e[:revenue] }
    total_ord = events.sum { |e| e[:orders] }
    { year: year, event_count: events.size, rev_count: rev_events.size, total_rev: total_rev, total_orders: total_ord,
      avg_rev: rev_events.any? ? (total_rev.to_f / rev_events.size).round(0) : 0,
      avg_orders: events.any? ? (total_ord.to_f / events.size).round(1) : 0,
      best_event: rev_events.max_by { |e| e[:revenue] } }
  end

  def avg_attendance(events, level)
    return 0 if events.empty?

    (events.sum { |e| e[:levels][level][:n] }.to_f / events.size).round(1)
  end

  def trend(prev, curr)
    return nil if prev.nil? || curr.nil? || prev.zero?

    pct_val = ((curr.to_f / prev - 1) * 100).round(0)
    { pct: pct_val, up: pct_val >= 0 }
  end

  def build_monthly_stats(event_hashes)
    monthly = Hash.new { |h, k| h[k] = { events: 0, rev: 0, rev_cnt: 0, att: 0, years: Set.new } }
    event_hashes.each do |e|
      m = e[:date].month
      monthly[m][:events] += 1
      monthly[m][:att] += e[:levels].values.sum { |d| d[:n] }
      monthly[m][:years] << e[:year]
      if e[:revenue] > 0
        monthly[m][:rev] += e[:revenue]
        monthly[m][:rev_cnt] += 1
      end
    end
    (1..12).filter_map do |m|
      d = monthly[m]
      next if d[:events].zero?

      { month: m, events: d[:events], avg_rev: d[:rev_cnt].positive? ? (d[:rev].to_f / d[:rev_cnt]).round(0) : nil,
        avg_att: (d[:att].to_f / d[:events]).round(1), years: d[:years].to_a.sort }
    end
  end

  # 產品系列：用 Livestream.product_keys 而非 note 字串比對（哪些場次含這個
  # 產品，一翻兩瞪眼；不像關鍵字比對可能漏字或誤判）。
  def build_series_stats(event_hashes)
    keys = CrmProduct.for_analysis.order(:label).pluck(:key, :label)
    series_data = Hash.new { |h, k| h[k] = { events: 0, rev: 0, rev_cnt: 0, att: 0 } }
    event_hashes.each do |e|
      matched_labels = keys.select { |k, _l| e[:product_keys]&.include?(k) }.map(&:last)
      matched_labels = ["其他"] if matched_labels.empty?
      matched_labels.each do |label|
        series_data[label][:events] += 1
        series_data[label][:att] += e[:levels].values.sum { |d| d[:n] }
        if e[:revenue] > 0
          series_data[label][:rev] += e[:revenue]
          series_data[label][:rev_cnt] += 1
        end
      end
    end
    raw_series = series_data.filter_map do |name, d|
      { name: name, events: d[:events], avg_rev: d[:rev_cnt].positive? ? (d[:rev].to_f / d[:rev_cnt]).round(0) : nil, avg_att: (d[:att].to_f / d[:events]).round(1) }
    end
    with_rev = raw_series.select { |s| s[:avg_rev] }
    global_mean = with_rev.sum { |s| s[:avg_rev] }.to_f / [with_rev.size, 1].max
    c = raw_series.sum { |s| s[:events] }.to_f / [raw_series.size, 1].max
    raw_series.map do |s|
      bayes = s[:avg_rev] ? ((c * global_mean + s[:events] * s[:avg_rev]) / (c + s[:events])).round(0) : 0
      s.merge(bayes_score: bayes)
    end.sort_by { |s| -s[:bayes_score] }
  end

  def build_gap_buckets(event_hashes)
    sorted = event_hashes.sort_by { |e| e[:date] }
    intervals = sorted.each_cons(2).map { |prev, curr| { gap: (curr[:date] - prev[:date]).to_i, att: curr[:levels].values.sum { |d| d[:n] }, rev: curr[:revenue], label: "#{curr[:year]}/#{curr[:label]}" } }
    buckets = [
      { label: "7–14 天", min: 7, max: 14 }, { label: "15–21 天", min: 15, max: 21 },
      { label: "22–30 天", min: 22, max: 30 }, { label: "31–45 天", min: 31, max: 45 }, { label: "46+ 天", min: 46, max: 9999 }
    ]
    gap_buckets = buckets.filter_map do |b|
      matching = intervals.select { |i| i[:gap] >= b[:min] && i[:gap] <= b[:max] }
      next if matching.empty?

      rev_events = matching.select { |i| i[:rev] > 0 }
      { label: b[:label], count: matching.size, avg_att: (matching.sum { |i| i[:att] }.to_f / matching.size).round(1),
        avg_rev: rev_events.any? ? (rev_events.sum { |i| i[:rev] }.to_f / rev_events.size).round(0) : nil }
    end
    best_gap = gap_buckets.max_by { |b| b[:avg_att] }
    [gap_buckets, best_gap&.dig(:label)]
  end

  def build_loyal_customers(emails, recent_events)
    return [] if emails.empty?

    ShoplineCustomer.where(email: emails).select(:id, :full_name, :email, :mobile_phone, :membership_level, :instagram_account, :total_amount).map do |c|
      attended = recent_events.select { |e| e[:db_emails].include?(c.email) }.map { |e| "#{e[:year]}/#{e[:label]}" }
      { customer: c, attended_labels: attended }
    end.sort_by { |r| [-MEMBERSHIP_RANK.fetch(r[:customer].membership_level, 0), -r[:customer].total_amount.to_f] }
  end

  def build_attendance_insights
    @insights = []
    return if @events_data.size < 2

    latest = @selected
    prev = @events_data[@events_data.index(@selected) - 1]
    return unless prev

    if @return_rates.any?
      rr = @return_rates.last
      if rr[:rate] >= 30
        @insights << { type: :success, text: "#{rr[:from]} → #{rr[:to]} 連場回流率 #{rr[:rate]}%（#{rr[:count]}/#{rr[:from_total]} 人），黏著度良好。" }
      else
        @insights << { type: :warning, text: "#{rr[:from]} → #{rr[:to]} 連場回流率 #{rr[:rate]}%（#{rr[:count]}/#{rr[:from_total]} 人），建議直播前 2 天主動通知。" }
      end
    end

    if @missing_customers.any?
      black_n = @missing_customers.count { |r| r[:customer].membership_level == "黑卡" }
      suffix = black_n.positive? ? "，其中 #{black_n} 位黑卡請優先聯繫" : ""
      @insights << { type: :danger, text: "#{@missing_customers.size} 位近期曾出席的客人 #{latest[:year]}/#{latest[:label]} 未出現#{suffix}。" }
    end

    @insights << { type: :success, text: "#{@loyal_3_customers.size} 位客人最近三場全勤，是核心忠實客，適合邀請為品牌大使。" } if @loyal_3_customers.size.positive?
    @insights << { type: :info, text: "#{@loyal_2_customers.size} 位客人近三場出席兩場，下場直播前建議主動通知。" } if @loyal_2_customers.size.positive?
  end

  def build_summaries
    items = []
    y25 = @years.find { |y| y[:year] == 2025 }
    y26 = @years.find { |y| y[:year] == 2026 }
    if y25 && y26 && y25[:avg_rev] > 0 && y26[:avg_rev] > 0
      pct_val = ((y26[:avg_rev].to_f / y25[:avg_rev] - 1) * 100).round(0)
      if pct_val >= 0
        items << { type: :success, text: "2026 場均業績 NT$#{fmt(y26[:avg_rev])}，較 2025 場均成長 #{pct_val}%。" }
      else
        items << { type: :warning, text: "2026 場均業績 NT$#{fmt(y26[:avg_rev])}，較 2025 場均下滑 #{pct_val.abs}%，建議檢視產品組合。" }
      end
    end

    best_grow = @level_by_year.select { |l| l[:trend_26] }.max_by { |l| l[:trend_26][:pct] }
    items << { type: :success, text: "#{best_grow[:level]} 2026 場均出席成長最快（↑#{best_grow[:trend_26][:pct]}%），是目前最活躍客群。" } if best_grow&.dig(:trend_26, :up)

    worst = @level_by_year.select { |l| l[:trend_26] && !l[:trend_26][:up] }.min_by { |l| l[:trend_26][:pct] }
    items << { type: :warning, text: "#{worst[:level]} 2026 場均出席下滑 #{worst[:trend_26][:pct].abs}%，需要特別關注。" } if worst

    top_series = @series_stats.find { |s| s[:avg_rev] }
    items << { type: :info, text: "產品系列中，「#{top_series[:name]}」場均業績最高（NT$#{fmt(top_series[:avg_rev])}），建議持續納入直播主打。" } if top_series

    best_month = @monthly_stats.select { |m| m[:avg_rev] }.max_by { |m| m[:avg_rev] }
    items << { type: :info, text: "#{best_month[:month]} 月是歷史場均業績最高的月份（NT$#{fmt(best_month[:avg_rev])}），建議每年安排重點場次。" } if best_month

    items << { type: :info, text: "場次間隔 #{@best_gap_label} 的直播，出席人數平均最高，建議作為排場頻率參考。" } if @best_gap_label

    b26 = @black_by_year.find { |b| b[:year] == 2026 }
    b25 = @black_by_year.find { |b| b[:year] == 2025 }
    if b26 && b25 && b25[:avg_n] > 0
      pct_val = ((b26[:avg_n].to_f / b25[:avg_n] - 1) * 100).round(0)
      if pct_val >= 0
        items << { type: :success, text: "黑卡客戶 2026 場均出席 #{b26[:avg_n]} 人（↑#{pct_val}%），VIP 黏著度提升。" }
      else
        items << { type: :warning, text: "黑卡客戶 2026 場均出席 #{b26[:avg_n]} 人（↓#{pct_val.abs}%），建議加強 VIP 邀約。" }
      end
    end

    items
  end

  def fmt(n)
    ActiveSupport::NumberHelper.number_to_delimited(n.to_i)
  end

  def pct(num, den)
    return 0.0 if den.zero?

    (num.to_f / den * 100).round(1)
  end
end
