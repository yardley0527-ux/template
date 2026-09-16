# frozen_string_literal: true

# AI數字幻覺防護第一步：把 WeeklyMetricsService 算好的關鍵數字整理成一份
# 「允許引用清單」（metric_key => raw_value/formatted_value/accepted_rounding/
# period），交給 WeeklyAiFactValidator 拿AI寫的文字去比對。AI理論上應該
# 直接引用這裡的 metric_key，但目前的prompt架構是自由文字輸出（v6沒有改成
# 強制AI標註metric_key再由renderer插入數字——那是更大的prompt/schema改造，
# 這一輪先用「事後比對」擋，見 weekly_ai_fact_validator.rb 的說明），所以這裡
# 只負責整理「允許值清單」本身，不強制AI的輸出格式。
#
# 範圍：只收錄會被AI在「一句話結論／最大風險／最大機會／營收分析／新舊客
# 分析／老闆決策事項／行動清單KPI」這幾個關鍵決策欄位引用到的核心數字，
# 不是把整份metrics鉅細靡遺攤平——鉅細靡遺會讓「找不到就算幻覺」的誤判率
# 暴增（例如商品明細、直播逐場數字目前不收錄，屬於後續工作，見
# WeeklyAiFactValidator 開頭註解列的範圍限制）。
class WeeklyMetricRegistry
  MONEY_ROUNDING   = 1    # 元，允許四捨五入誤差1元（浮點數運算殘差）
  COUNT_ROUNDING   = 0    # 人數，必須整數相符
  PERCENT_ROUNDING = 0.1  # 百分比，允許0.1個百分點誤差

  def self.call(metrics)
    new(metrics).call
  end

  def initialize(metrics)
    @m = metrics || {}
  end

  def call
    entries = {}
    add_revenue_decomposition(entries)
    add_customer_segments(entries)
    add_revenue_progress(entries)
    add_derived_metrics(entries)
    entries
  end

  private

  def add(entries, key, raw:, period:, kind:, rounding:, claim_type: "observed_metric")
    return if raw.nil?

    entries[key] = {
      "metric_key"        => key,
      "raw_value"          => raw.to_f,
      "formatted_value"    => format_value(raw, kind),
      "accepted_rounding"  => rounding,
      "period"             => period,
      "kind"               => kind,
      "claim_type"         => claim_type
    }
  end

  # 衍生計算值（差額／比較兩個已知指標算出來的新數字）——由程式先算好、
  # 標上formula跟source_metric_keys放進清單，不要留給validator自己嘗試把
  # AI寫的數字拿去跟任意兩個metric做排列組合湊出來比對（那樣做風險是隨著
  # metric數量增加，湊出「剛好對得上」的組合會越來越多，反而製造新的
  # 誤判——所以只有這裡明確登記過的固定公式才算derived_metric，不是通用
  # 引擎。
  def add_derived(entries, key, raw:, period:, kind:, rounding:, formula:, source_metric_keys:)
    return if raw.nil?

    add(entries, key, raw: raw, period: period, kind: kind, rounding: rounding, claim_type: "derived_metric")
    entries[key]["formula"] = formula
    entries[key]["source_metric_keys"] = source_metric_keys
  end

  def format_value(raw, kind)
    case kind
    when "money"   then "#{number_with_delimiter(raw.round)}元"
    when "count"   then "#{number_with_delimiter(raw.round)}人"
    when "percent" then "#{raw.round(1)}%"
    else raw.to_s
    end
  end

  def number_with_delimiter(n)
    n.to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1,').reverse
  end

  # ── 營收拆解（購買人數／客單價／營收，各基準期）＋成長率 ─────────
  def add_revenue_decomposition(entries)
    nvr = @m["new_vs_returning"] || {}
    this_week   = nvr["this_week"] || {}
    prev_week   = nvr["prev_week"] || {}
    trailing4   = nvr["trailing4_weekly_avg"] || {}
    last_year   = nvr["last_year_same_week"] || {}
    decomp      = nvr["decomposition"] || {}

    add(entries, "revenue.this_week", raw: this_week["total_revenue"], period: "本週", kind: "money", rounding: MONEY_ROUNDING)
    add(entries, "revenue.prev_week", raw: prev_week["total_revenue"], period: "上週", kind: "money", rounding: MONEY_ROUNDING)
    add(entries, "revenue.trailing4_avg", raw: trailing4["total_revenue"], period: "近四週平均", kind: "money", rounding: MONEY_ROUNDING)
    add(entries, "revenue.last_year_same_week", raw: last_year["total_revenue"], period: "去年同週", kind: "money", rounding: MONEY_ROUNDING)
    add(entries, "revenue.growth_vs_trailing4_pct", raw: decomp["revenue_growth_vs_trailing4_pct"], period: "本週vs近四週平均", kind: "percent", rounding: PERCENT_ROUNDING)
    add(entries, "revenue.growth_vs_last_year_pct", raw: decomp["revenue_growth_vs_last_year_pct"], period: "本週vs去年同週", kind: "percent", rounding: PERCENT_ROUNDING)

    add(entries, "purchase_count.this_week", raw: this_week["total_customers"], period: "本週", kind: "count", rounding: COUNT_ROUNDING)
    add(entries, "purchase_count.prev_week", raw: prev_week["total_customers"], period: "上週", kind: "count", rounding: COUNT_ROUNDING)
    add(entries, "purchase_count.trailing4_avg", raw: trailing4["total_customers"], period: "近四週平均", kind: "count", rounding: COUNT_ROUNDING)
    add(entries, "purchase_count.last_year_same_week", raw: last_year["total_customers"], period: "去年同週", kind: "count", rounding: COUNT_ROUNDING)
    add(entries, "purchase_count.growth_vs_trailing4_pct", raw: decomp["customers_growth_vs_trailing4_pct"], period: "本週vs近四週平均", kind: "percent", rounding: PERCENT_ROUNDING)
    add(entries, "purchase_count.growth_vs_last_year_pct", raw: decomp["customers_growth_vs_last_year_pct"], period: "本週vs去年同週", kind: "percent", rounding: PERCENT_ROUNDING)

    add(entries, "aov.this_week", raw: decomp["this_week_overall_aov"], period: "本週", kind: "money", rounding: MONEY_ROUNDING)
    add(entries, "aov.trailing4_avg", raw: decomp["trailing4_weekly_avg_overall_aov"], period: "近四週平均", kind: "money", rounding: MONEY_ROUNDING)
    add(entries, "aov.last_year_same_week", raw: decomp["last_year_same_week_overall_aov"], period: "去年同週", kind: "money", rounding: MONEY_ROUNDING)
    add(entries, "aov.growth_vs_trailing4_pct", raw: decomp["overall_aov_growth_vs_trailing4_pct"], period: "本週vs近四週平均", kind: "percent", rounding: PERCENT_ROUNDING)
  end

  # ── 新客／舊客各期人數、營收、客單價 ─────────────────────────────
  def add_customer_segments(entries)
    nvr = @m["new_vs_returning"] || {}
    this_week = nvr["this_week"] || {}
    trailing4 = nvr["trailing4_weekly_avg"] || {}
    last_year = nvr["last_year_same_week"] || {}
    decomp    = nvr["decomposition"] || {}

    add(entries, "new_customer.count.this_week", raw: this_week["new_customers"], period: "本週", kind: "count", rounding: COUNT_ROUNDING)
    add(entries, "new_customer.count.trailing4_avg", raw: trailing4["new_customers"], period: "近四週平均", kind: "count", rounding: COUNT_ROUNDING)
    add(entries, "new_customer.count.last_year_same_week", raw: last_year["new_customers"], period: "去年同週", kind: "count", rounding: COUNT_ROUNDING)
    add(entries, "new_customer.count.growth_vs_trailing4_pct", raw: decomp["new_customers_growth_vs_trailing4_pct"], period: "本週vs近四週平均", kind: "percent", rounding: PERCENT_ROUNDING)
    add(entries, "new_customer.count.growth_vs_last_year_pct", raw: decomp["new_customers_growth_vs_last_year_pct"], period: "本週vs去年同週", kind: "percent", rounding: PERCENT_ROUNDING)
    add(entries, "new_customer.revenue.this_week", raw: this_week["new_revenue"], period: "本週", kind: "money", rounding: MONEY_ROUNDING)
    add(entries, "new_customer.revenue.trailing4_avg", raw: trailing4["new_revenue"], period: "近四週平均", kind: "money", rounding: MONEY_ROUNDING)
    add(entries, "new_customer.revenue.last_year_same_week", raw: last_year["new_revenue"], period: "去年同週", kind: "money", rounding: MONEY_ROUNDING)
    add(entries, "new_customer.aov.this_week", raw: this_week["new_aov"], period: "本週", kind: "money", rounding: MONEY_ROUNDING)
    add(entries, "new_customer.aov.trailing4_avg", raw: trailing4["new_aov"], period: "近四週平均", kind: "money", rounding: MONEY_ROUNDING)
    add(entries, "new_customer.aov.last_year_same_week", raw: last_year["new_aov"], period: "去年同週", kind: "money", rounding: MONEY_ROUNDING)

    add(entries, "returning_customer.count.this_week", raw: this_week["returning_customers"], period: "本週", kind: "count", rounding: COUNT_ROUNDING)
    add(entries, "returning_customer.count.trailing4_avg", raw: trailing4["returning_customers"], period: "近四週平均", kind: "count", rounding: COUNT_ROUNDING)
    add(entries, "returning_customer.count.last_year_same_week", raw: last_year["returning_customers"], period: "去年同週", kind: "count", rounding: COUNT_ROUNDING)
    add(entries, "returning_customer.revenue.this_week", raw: this_week["returning_revenue"], period: "本週", kind: "money", rounding: MONEY_ROUNDING)
    add(entries, "returning_customer.revenue.trailing4_avg", raw: trailing4["returning_revenue"], period: "近四週平均", kind: "money", rounding: MONEY_ROUNDING)
    add(entries, "returning_customer.revenue.last_year_same_week", raw: last_year["returning_revenue"], period: "去年同週", kind: "money", rounding: MONEY_ROUNDING)
    add(entries, "returning_customer.revenue.growth_vs_last_year_pct", raw: decomp["returning_revenue_growth_vs_last_year_pct"], period: "本週vs去年同週", kind: "percent", rounding: PERCENT_ROUNDING)
    add(entries, "returning_customer.aov.this_week", raw: this_week["returning_aov"], period: "本週", kind: "money", rounding: MONEY_ROUNDING)
    add(entries, "returning_customer.aov.trailing4_avg", raw: trailing4["returning_aov"], period: "近四週平均", kind: "money", rounding: MONEY_ROUNDING)
    add(entries, "returning_customer.aov.last_year_same_week", raw: last_year["returning_aov"], period: "去年同週", kind: "money", rounding: MONEY_ROUNDING)
    add(entries, "returning_customer.aov.growth_vs_last_year_pct", raw: decomp["returning_aov_growth_vs_last_year_pct"], period: "本週vs去年同週", kind: "percent", rounding: PERCENT_ROUNDING)
    add(entries, "returning_customer.aov.growth_vs_trailing4_pct", raw: decomp["returning_aov_growth_vs_trailing4_pct"], period: "本週vs近四週平均", kind: "percent", rounding: PERCENT_ROUNDING)
  end

  # ── 年度營收安全線／預測相關的關鍵累計數字 ───────────────────────
  def add_revenue_progress(entries)
    rp = @m["revenue_progress"] || {}

    add(entries, "revenue_progress.ytd", raw: rp["ytd_revenue"], period: "今年累計", kind: "money", rounding: MONEY_ROUNDING)
    add(entries, "revenue_progress.last_year_same_period", raw: rp["last_year_same_period_ytd_revenue"], period: "去年同期累計", kind: "money", rounding: MONEY_ROUNDING)
    add(entries, "revenue_progress.last_year_full_year", raw: rp["last_year_full_year_revenue"], period: "去年全年", kind: "money", rounding: MONEY_ROUNDING)
    add(entries, "revenue_progress.gap_to_beat_last_year", raw: rp["gap_to_beat_last_year"], period: "距離去年全年差額", kind: "money", rounding: MONEY_ROUNDING)
    add(entries, "revenue_progress.yoy_growth_pct", raw: rp["yoy_growth_pct"], period: "今年累計vs去年同期", kind: "percent", rounding: PERCENT_ROUNDING)
  end

  # ── 已知會被AI引用的衍生差額 ───────────────────────────────────
  def add_derived_metrics(entries)
    rp = @m["revenue_progress"] || {}
    ytd = rp["ytd_revenue"]
    last_year_same_period = rp["last_year_same_period_ytd_revenue"]

    if ytd && last_year_same_period
      add_derived(
        entries, "revenue_progress.ytd_lead_over_last_year_same_period",
        raw: ytd - last_year_same_period, period: "今年累計vs去年同期", kind: "money", rounding: MONEY_ROUNDING,
        formula: "revenue_progress.ytd - revenue_progress.last_year_same_period",
        source_metric_keys: %w[revenue_progress.ytd revenue_progress.last_year_same_period]
      )
    end
  end
end
