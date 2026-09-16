# frozen_string_literal: true

# 老闆30秒摘要的「週型」——不是單純的直播週/自然週（那是 WeeklyWeekTypeClassifier
# 的事），而是「本週經營故事的標題」，例如「活動後回落／新客不足警戒週」。
# 一律由規則算出，最多顯示兩個標籤（主標籤：這週本身是不是活動/活動後高
# 基期；副標籤：本週最急迫的警戒訊號），不是 AI 自由發揮。
class WeeklyHeadlineClassifier
  PRIMARY_LABELS = {
    "campaign_growth_week"    => "活動成長週",
    "campaign_underperform"   => nil, # 用 base_week_type 的 type_label，不另外命名
    "post_event_pullback"     => "活動後回落週",
    "normal_week"             => "一般經營週"
  }.freeze

  # 依規格例示順序：新客不足 > 舊客回購不足 > 客單價下滑 > 庫存阻斷 > 資料不足待確認
  WARNING_ORDER = %w[new_customer_warning old_customer_warning aov_warning inventory_warning insufficient_data_warning].freeze
  WARNING_LABELS = {
    "new_customer_warning"     => "新客不足警戒週",
    "old_customer_warning"     => "舊客回購不足警戒週",
    "aov_warning"               => "客單價下滑週",
    "inventory_warning"         => "庫存阻斷週",
    "insufficient_data_warning" => "資料不足待確認週"
  }.freeze

  def self.call(period:, metrics:, risk_flags:, business_signals:)
    new(period, metrics, risk_flags, business_signals).call
  end

  def initialize(period, metrics, risk_flags, business_signals)
    @period = period
    @m = metrics
    @flags = Array(risk_flags)
    @signals = Array(business_signals)
  end

  def call
    primary_key, primary_label = primary
    warning_key = top_warning

    labels = [primary_label].compact
    labels << WARNING_LABELS.fetch(warning_key) if warning_key

    # 組合顯示時（例如「活動後回落／新客不足警戒週」）只有最後一個標籤保留
    # 結尾的「週」字，前面的標籤去掉，避免「活動後回落週／新客不足警戒週」
    # 這種疊字讀起來卡卡的——這是純顯示層的處理，labels 陣列本身仍保留完整
    # 名稱給其他呼叫端（例如附錄）使用。
    display = labels.each_with_index.map { |l, i| i < labels.size - 1 ? l.delete_suffix("週") : l }.join("／")

    {
      "primary_key"   => primary_key,
      "warning_key"   => warning_key,
      "labels"        => labels,
      "display"       => display,
      "base_week_type" => @m.dig("week_type", "type"),
      "prev_week_had_event" => prev_week_had_event?
    }
  end

  private

  def this_week_has_event?
    @m.dig("week_type", "type") != "normal_week"
  end

  def prev_week_had_event?
    Livestream.where(date: @period.prev_week_range).exists? ||
      CalendarEvent.where(event_type: "campaign", event_date: @period.prev_week_range).exists?
  end

  def has_high_flag?(category)
    @flags.any? { |f| (f[:category] || f["category"]).to_s == category && (f[:severity] || f["severity"]) == "high" }
  end

  def primary
    if this_week_has_event? && !has_high_flag?("revenue")
      ["campaign_growth_week", PRIMARY_LABELS["campaign_growth_week"]]
    elsif this_week_has_event?
      ["campaign_underperform", @m.dig("week_type", "type_label")]
    elsif prev_week_had_event?
      ["post_event_pullback", PRIMARY_LABELS["post_event_pullback"]]
    else
      ["normal_week", PRIMARY_LABELS["normal_week"]]
    end
  end

  def top_warning
    gray_count = @signals.count { |s| s["status"] == "gray" }

    WARNING_ORDER.find do |key|
      case key
      when "new_customer_warning"     then has_high_flag?("new_customer")
      when "old_customer_warning"     then has_high_flag?("old_customer")
      when "aov_warning"               then @flags.any? { |f| (f[:key] || f["key"]).to_s == "overall_aov_drop_vs_avg4" && (f[:severity] || f["severity"]) == "high" }
      when "inventory_warning"         then has_high_flag?("product_inventory")
      when "insufficient_data_warning" then gray_count >= 2
      end
    end
  end
end
