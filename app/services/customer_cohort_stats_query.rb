# frozen_string_literal: true

# 首購產品分析頁面的統計，全部用 SQL 在 customer_cohort_stats 上彙總，
# 不把整張表載進 web 程序（名單只取當頁 50 筆）
class CustomerCohortStatsQuery
  WINDOWS = [30, 60, 90].freeze
  PERIODS = {
    "" => "全部",
    "2026" => "2026 年首購",
    "2025" => "2025 年首購",
    "2024" => "2024 年首購",
    "180" => "近 180 天首購"
  }.freeze

  def initialize(period: "", today: Date.current)
    @period = PERIODS.key?(period.to_s) ? period.to_s : ""
    @today = today
  end

  attr_reader :period

  def scope
    s = CustomerCohortStat.all
    case @period
    when "2024", "2025", "2026" then s.where(first_date: Date.new(@period.to_i, 1, 1)..Date.new(@period.to_i, 12, 31))
    when "180" then s.where("first_date >= ?", @today - 180)
    else s
    end
  end

  # { "代謝錠" => summary, ... }（依 CustomerCohortStatsRefreshService.sources 排序、沒人的不列）
  def overview
    rows = aggregate(scope).group(:source).pluck(:source, *aggregate_columns)
    cross = scope.joins("CROSS JOIN LATERAL UNNEST(customer_cohort_stats.cross_families) AS fam")
                 .group(:source, "fam").order(Arel.sql("COUNT(*) DESC")).pluck(:source, Arel.sql("fam"), Arel.sql("COUNT(*)"))
                 .group_by(&:first)
    order = CustomerCohortStatsRefreshService.sources
    rows.sort_by { |r| order.index(r[0]) || 99 }.to_h do |source, *vals|
      summary = build_summary(vals)
      summary[:cross] = (cross[source] || []).first(3).to_h { |_, fam, n| [fam, { people: n, revenue: 0 }] }
      [source, summary]
    end
  end

  def summary(source)
    s = scope.where(source: source)
    vals = aggregate(s).pick(*aggregate_columns)
    summary = build_summary(vals || [])
    summary[:cross] = s.joins("CROSS JOIN LATERAL UNNEST(customer_cohort_stats.cross_families) AS fam")
                       .group("fam").order(Arel.sql("COUNT(*) DESC"))
                       .pluck(Arel.sql("fam"), Arel.sql("COUNT(*)"), Arel.sql("SUM((cross_revenue ->> fam)::numeric)"))
                       .to_h { |fam, n, rev| [fam, { people: n, revenue: rev.to_f }] }
    summary[:upgrade_paths] = s.where(upgraded: true).group(:level_at_first, :level_now).order(Arel.sql("COUNT(*) DESC")).count
                               .transform_keys { |(a, b)| "#{a} → #{b}" }
    summary
  end

  def refreshed_at
    CustomerCohortStat.maximum(:refreshed_at)
  end

  private

  def aggregate(rel)
    rel.unscope(:order)
  end

  def aggregate_columns
    cols = [
      "COUNT(*)",
      "COUNT(*) FILTER (WHERE after_days > 0)",
      "COUNT(*) FILTER (WHERE same_again)",
      "COALESCE(SUM(after_amount) FILTER (WHERE after_days > 0), 0)",
      "COALESCE(AVG(after_days) FILTER (WHERE after_days > 0), 0)",
      "COALESCE(AVG(first_amount), 0)",
      "COUNT(*) FILTER (WHERE upgraded)"
    ]
    WINDOWS.each do |n|
      cutoff = ActiveRecord::Base.connection.quote(@today - n)
      cols << "COUNT(*) FILTER (WHERE first_date <= #{cutoff})"
      cols << "COUNT(*) FILTER (WHERE first_date <= #{cutoff} AND first_after_date <= first_date + #{n})"
    end
    cols.map { |c| Arel.sql(c) }
  end

  def build_summary(vals)
    total, back, same, after_amt, avg_days, avg_first, upgraded, *w = vals.map { |v| v || 0 }
    {
      total: total.to_i,
      repurchased: back.to_i,
      same_again: same.to_i,
      after_amount: after_amt.to_f,
      avg_after_days: avg_days.to_f.round(1),
      avg_first_amount: avg_first.to_f.round,
      upgraded: upgraded.to_i,
      windows: WINDOWS.each_with_index.to_h { |n, i| [n, { eligible: w[i * 2].to_i, hit: w[i * 2 + 1].to_i }] },
      cross: {},
      upgrade_paths: {}
    }
  end
end
