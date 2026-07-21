# frozen_string_literal: true

# Phase 0A Shadow Mode：唯讀比較「現行 rollup 瓶數邏輯」與各候選折疊方式，
# 不寫入任何資料表、不影響任何頁面。正式切換（PR-A）前的證據來源。
#
#   report = BottleFoldingShadowReport.call(product_key: "metabolism")
#   report[:summary]   # 影響筆數、diff 原因分布、expected_return_date 位移、狀態桶增減
#   report[:rows]      # 每客戶明細（email 僅供內部核對，呼叫端輸出時需遮罩）
#
# 六種瓶數：
#   v1_current        現行 service（最後一列，regex→括號→1，＋送N；無 quantity、無家庭號）
#   v2_extractor      BottleExtractor（最後一列；含家庭號 override；regex 來自 crm_products）
#   v3_qty            v2 × 該列 quantity
#   v4_day_max        最後購買日各列 (extractor×qty) 取最大
#   v5_day_sum        最後購買日各列 (extractor×qty) 加總
#   v6_order_fold     建議法：先按 order_number 分組加總、再跨訂單加總
#                     （數值上 = v5；差別在同單同內容列會被標記 same_order_duplicate_candidate
#                     供人工核對，而不是被 DISTINCT 摺掉——同單買兩組同商品可能是真實購買）
class BottleFoldingShadowReport
  ELIGIBILITY_WINDOW_DAYS = 365

  BUCKETS = %w[not_yet runout_0_7 runout_8_14 overdue_1_60 at_risk].freeze

  def self.call(product_key:)
    new(product_key: product_key).call
  end

  def initialize(product_key:)
    @product_key = product_key
    @product     = JourneyProducts::PRODUCTS.fetch(product_key)
    @extractor   = BottleExtractor.new(product_key)
    @extractor_regex_present = CrmProduct.find_by(key: product_key)&.regex_pattern.present?
    # 預先編譯一次，避免每列都重新解析 8 個產品的 LIKE pattern。
    @other_product_regexes = JourneyProducts::PRODUCTS.values.map { |p| like_to_regex(p[:sql]) }
  end

  def call
    rows = build_rows
    { product_key: @product_key,
      extractor_regex_present: @extractor_regex_present,
      rows: rows,
      summary: summarize(rows) }
  end

  private

  def build_rows
    lines_by_email = fetch_lines.group_by { |l| l[:email] }

    lines_by_email.map do |email, lines|
      last_line = lines.max_by { |l| l[:order_time] }
      last_date = last_line[:order_date]
      day_lines = lines.select { |l| l[:order_date] == last_date }

      v1 = current_service_bottles(last_line[:product_name])
      v2 = @extractor.extract(last_line[:product_name])
      v3 = v2 * [last_line[:quantity].to_i, 1].max
      per_line = day_lines.map { |l| @extractor.extract(l[:product_name]) * [l[:quantity].to_i, 1].max }
      v4 = per_line.max
      v5 = per_line.sum
      v6 = day_lines.group_by { |l| l[:order_number] }
                    .sum { |_on, ls| ls.sum { |l| @extractor.extract(l[:product_name]) * [l[:quantity].to_i, 1].max } }

      {
        email: email,
        last_date: last_date,
        day_line_count: day_lines.size,
        day_order_count: day_lines.map { |l| l[:order_number] }.uniq.size,
        v1_current: v1, v2_extractor: v2, v3_qty: v3,
        v4_day_max: v4, v5_day_sum: v5, v6_order_fold: v6,
        reasons: diff_reasons(last_line, day_lines, v1, v6),
        expected_v1: last_date + expected_days(v1),
        expected_v6: last_date + expected_days(v6),
        last_total_amount: last_line[:total_amount]
      }
    end
  end

  def fetch_lines
    since = Date.current - ELIGIBILITY_WINDOW_DAYS

    ShoplineOrder
      .where(@product[:sql])
      .where("order_date >= ?", since.beginning_of_day)
      .where.not(email: [nil, ""])
      .pluck(:email, :order_number, :product_name, :quantity, :checkout_amount, :total_amount, :order_date)
      .map do |email, order_number, product_name, quantity, checkout_amount, total_amount, order_time|
        { email: email, order_number: order_number, product_name: product_name,
          quantity: quantity, checkout_amount: checkout_amount,
          total_amount: total_amount, order_time: order_time,
          order_date: order_time.to_date }
      end
  end

  # ── 差異原因分類 ──────────────────────────────────────────────

  def diff_reasons(last_line, day_lines, v1, v6)
    reasons = []
    name = last_line[:product_name].to_s

    reasons << "household_override"      if household_override?(name)
    reasons << "quantity_multiplier"     if day_lines.any? { |l| l[:quantity].to_i > 1 }
    reasons << "same_day_multiple_orders" if day_lines.map { |l| l[:order_number] }.uniq.size > 1
    reasons << "same_order_duplicate_candidate" if same_order_duplicate?(day_lines)
    reasons << "bundle_multi_product"    if bundle_multi_product?(name)
    reasons << "gift"                    if name.match?(/[送贈]/)
    reasons << "extractor_regex_missing" unless @extractor_regex_present
    reasons << "unknown" if reasons.empty? && v1 != v6
    reasons
  end

  def household_override?(name)
    (BottleExtractor::SUBSTRING_OVERRIDES[@product_key] || {}).keys.any? { |s| name.include?(s) }
  end

  # 同一 order_number 內出現內容完全相同的兩列（品名＋數量＋金額）。
  # 可能是殘留重複列，也可能是真實買兩組——只標記、不摺疊。
  def same_order_duplicate?(day_lines)
    day_lines.group_by { |l| [l[:order_number], l[:product_name], l[:quantity], l[:checkout_amount]] }
             .any? { |_k, ls| ls.size > 1 }
  end

  def bundle_multi_product?(name)
    @other_product_regexes.count { |re| name.match?(re) } >= 2
  end

  def like_to_regex(like_sql)
    keyword = like_sql[/LIKE '%(.+)%'/, 1]
    /#{Regexp.escape(keyword)}/
  end

  # ── 彙總 ─────────────────────────────────────────────────────

  def summarize(rows)
    changed = rows.reject { |r| r[:v1_current] == r[:v6_order_fold] }
    shifts  = changed.map { |r| (r[:expected_v6] - r[:expected_v1]).to_i }

    {
      total_rows: rows.size,
      changed_rows: changed.size,
      reason_counts: changed.flat_map { |r| r[:reasons] }.tally.sort_by { |_r, c| -c }.to_h,
      shift_distribution: shift_buckets(shifts),
      bucket_moves: bucket_moves(rows),
      high_value_affected: changed.count { |r| r[:last_total_amount].to_f >= 30_000 }
    }
  end

  def shift_buckets(shifts)
    {
      "later_31d+"   => shifts.count { |s| s > 30 },
      "later_8_30d"  => shifts.count { |s| s.between?(8, 30) },
      "later_1_7d"   => shifts.count { |s| s.between?(1, 7) },
      "no_shift"     => shifts.count(&:zero?),
      "earlier_1_7d" => shifts.count { |s| s.between?(-7, -1) },
      "earlier_8d+"  => shifts.count { |s| s < -7 }
    }
  end

  def bucket_moves(rows)
    moves = Hash.new(0)
    rows.each do |r|
      from = bucket_for(r[:expected_v1])
      to   = bucket_for(r[:expected_v6])
      moves["#{from}->#{to}"] += 1 if from != to
    end
    moves.sort_by { |_k, v| -v }.to_h
  end

  def bucket_for(expected_date)
    days_left = (expected_date - Date.current).to_i
    return "runout_0_7"   if days_left.between?(0, 7)
    return "runout_8_14"  if days_left.between?(8, 14)
    return "overdue_1_60" if days_left.between?(-60, -1)
    return "at_risk"      if days_left < -60

    "not_yet"
  end

  # ── 現行 service 邏輯的忠實鏡像（勿改：這是 baseline）──────────

  def current_service_bottles(product_name)
    return 1 if product_name.nil?

    m = product_name.match(@product[:regex])
    base = if m
      m[1].to_i
    elsif (m2 = product_name.match(/[（(](\d+)[瓶盒]/))
      m2[1].to_i
    else
      1
    end
    base + (product_name.match(/送(\d+)/)&.[](1).to_i || 0)
  end

  def expected_days(bottles)
    medians = @product[:medians]
    return medians[bottles] if medians.key?(bottles)

    keys = medians.keys.sort
    lo = keys.select { |k| k < bottles }.last
    hi = keys.select { |k| k > bottles }.first
    return medians[lo || hi] unless lo && hi

    lo_v = medians[lo]
    hi_v = medians[hi]
    (lo_v + (hi_v - lo_v).to_f * (bottles - lo) / (hi - lo)).round
  end
end
