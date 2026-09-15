# frozen_string_literal: true

# 判斷一週是「直播週」「活動週」「一般自然週」，讓 WeeklyMetricsService 選對
# 比較基準——不能無腦拿本週跟上週比，因為上週可能是直播/活動高基期。
#
# 資料來源：Livestream（既有直播記錄，日期精確）、CalendarEvent(event_type:
# "campaign")（既有行銷活動行事曆，AnnualCalendarSync 維護）。CRM 目前沒有
# 「活動規模（大型/一般促銷）」的分級欄位，所以活動週一律標成同一類，规模
# 判斷交给人工——不自行臆測活動內容或規模（見 CLAUDE 指示）。
class WeeklyWeekTypeClassifier
  def self.call(period)
    new(period).call
  end

  def initialize(period)
    @period = period
  end

  def call
    livestreams = Livestream.where(date: @period.range).order(:date).to_a
    campaigns   = CalendarEvent.where(event_type: "campaign", event_date: @period.range).order(:event_date).to_a

    type = if livestreams.any? && campaigns.any?
             "livestream_and_campaign_week"
           elsif livestreams.any?
             "livestream_week"
           elsif campaigns.any?
             "campaign_week"
           else
             "normal_week"
           end

    {
      "type"                => type,
      "type_label"          => LABELS.fetch(type),
      "livestream_dates"    => livestreams.map(&:date),
      "campaign_titles"     => campaigns.map(&:title),
      "campaign_size_known" => false,
      "campaign_size_note"  => campaigns.any? ? "CRM 沒有活動規模分級資料，無法自動判斷是大型檔期還是一般促銷，需人工確認" : nil
    }
  end

  LABELS = {
    "livestream_and_campaign_week" => "直播週（同時有行銷活動）",
    "livestream_week"              => "直播週",
    "campaign_week"                => "活動週（規模需人工確認）",
    "normal_week"                  => "一般自然週"
  }.freeze

  # 找「同類型」的歷史週，供 WeeklyMetricsService 算可比較基準用。
  # normal_week 找最近 N 個同樣是 normal_week 的完整週；livestream_week 找最近
  # N 個也有直播的週；campaign_week 目前資料不足以細分，一律退回 normal_week
  # 基準並標註限制。一次撈整個回溯區間的直播/活動日期，避免對每一週各發一次查詢。
  def self.comparable_week_starts(period, count: 4, lookback_weeks: 26)
    range_start = period.week_start - (7 * lookback_weeks)
    livestream_dates = Livestream.where(date: range_start...period.week_start).pluck(:date)
    campaign_dates   = CalendarEvent.where(event_type: "campaign", event_date: range_start...period.week_start).pluck(:event_date)

    this_type = call(period)["type"]
    wants_livestream = this_type.start_with?("livestream")

    (1..lookback_weeks).filter_map do |n|
      ws = period.week_start - (7 * n)
      we = ws + 6
      has_livestream = livestream_dates.any? { |d| d.between?(ws, we) }
      has_campaign   = campaign_dates.any? { |d| d.between?(ws, we) }

      is_match = wants_livestream ? has_livestream : (!has_livestream && !has_campaign)
      ws if is_match
    end.first(count)
  end
end
