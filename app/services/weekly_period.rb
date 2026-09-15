# frozen_string_literal: true

# 集中定義「每週營運檢討報告」用到的所有時間區間，讓 WeeklyMetricsService、
# WeeklyBriefingService、controller 共用同一份切法，不會各自算出不同的週界。
#
# 週期一律週一 00:00 ～ 週日 23:59（Asia/Taipei，config.time_zone 已設 'Taipei'）。
class WeeklyPeriod
  attr_reader :week_start, :week_end

  def initialize(reference_date = Date.current)
    @week_start = reference_date.to_date.beginning_of_week(:monday)
    @week_end   = @week_start + 6
  end

  def self.for_week_start(week_start)
    new(week_start.to_date)
  end

  # 「正式週報」的預設週期——最新一個已經完整結束的週一~週日。今天是週二
  # 時，本週(週一~週日)還沒過完，正式週報預設要退回上一週，不能拿只過了
  # 一兩天的本週跟上週完整7天比較（見 2026-09-15 第五輪修正）。
  def self.latest_complete_week_start(reference_date = Date.current)
    new(reference_date).prev_week_start
  end

  # 這個週期本身（週一~週日）是否已經完整結束——用「今天」判斷，不是用
  # 產生報告當下的時間，這樣同一筆資料在不同天讀取，這個判斷結果不會變。
  def complete?(reference_date = Date.current)
    week_end < reference_date
  end

  def range
    week_start..week_end
  end

  def time_range
    week_start.beginning_of_day..week_end.end_of_day
  end

  def prev_week_start
    week_start - 7
  end

  def prev_week_end
    week_start - 1
  end

  def prev_week_range
    prev_week_start..prev_week_end
  end

  def prev_week_time_range
    prev_week_start.beginning_of_day..prev_week_end.end_of_day
  end

  # 近 4 週：本週「之前」已完整結束的 4 週（不含本週，避免拿本週跟自己比）。
  def trailing4_start
    week_start - 28
  end

  def trailing4_end
    week_start - 1
  end

  def trailing4_range
    trailing4_start..trailing4_end
  end

  def trailing4_time_range
    trailing4_start.beginning_of_day..trailing4_end.end_of_day
  end

  def ytd_start
    Date.new(week_end.year, 1, 1)
  end

  def ytd_range
    ytd_start..week_end
  end

  def ytd_time_range
    ytd_start.beginning_of_day..week_end.end_of_day
  end

  # 去年同期（同一年度累計天數起訖），Date.new 遇到 2/29 這種去年沒有的日期
  # 會拋 ArgumentError，退一天取代（去年最後一個有效日）。
  def last_year_same_period_end
    safe_date(week_end.year - 1, week_end.month, week_end.day)
  end

  def last_year_same_period_range
    Date.new(week_end.year - 1, 1, 1)..last_year_same_period_end
  end

  def last_year_same_period_time_range
    Date.new(week_end.year - 1, 1, 1).beginning_of_day..last_year_same_period_end.end_of_day
  end

  # 去年同一週（供直播/新舊客單週 YoY 比較用）。
  def last_year_same_week_start
    safe_date(week_start.year - 1, week_start.month, week_start.day)
  end

  def last_year_same_week_range
    last_year_same_week_start..(last_year_same_week_start + 6)
  end

  def last_year_start
    Date.new(week_end.year - 1, 1, 1)
  end

  def last_year_end
    Date.new(week_end.year - 1, 12, 31)
  end

  def last_year_range
    last_year_start..last_year_end
  end

  def last_year_time_range
    last_year_start.beginning_of_day..last_year_end.end_of_day
  end

  def days_remaining_in_year
    (Date.new(week_end.year, 12, 31) - week_end).to_i
  end

  def weeks_remaining_in_year
    (days_remaining_in_year / 7.0)
  end

  # 2026-09-15 修正：這個 hash 會被塞進 WeeklyMetricsService 的
  # "period" => @period.as_json，跟其餘全篇用字串鍵的 metrics 混在一起——
  # 原本用符號鍵，導致 metrics["period"]["week_start"] 這種字串鍵查找永遠
  # 讀到 nil（跟 data_gaps 先前踩過的同一類 bug），這裡統一轉字串鍵。
  def as_json(*)
    {
      "week_start" => week_start, "week_end" => week_end,
      "prev_week_start" => prev_week_start, "prev_week_end" => prev_week_end,
      "trailing4_start" => trailing4_start, "trailing4_end" => trailing4_end,
      "ytd_start" => ytd_start,
      "last_year_same_period_start" => Date.new(week_end.year - 1, 1, 1),
      "last_year_same_period_end" => last_year_same_period_end,
      "last_year_start" => last_year_start, "last_year_end" => last_year_end,
      "days_remaining_in_year" => days_remaining_in_year,
      "complete" => complete?
    }
  end

  private

  def safe_date(year, month, day)
    Date.new(year, month, day)
  rescue ArgumentError
    Date.new(year, month, day - 1)
  end
end
