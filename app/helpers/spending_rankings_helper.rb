# frozen_string_literal: true

module SpendingRankingsHelper
  # 同期 YoY 顯示：+28.6% / -43.2% / 0.0%；2025 同期為 0 時 2026 也 0 → —，2026 > 0 → NEW
  def yoy_rate_display(row)
    if row[:amount_2025_ytd].zero?
      row[:amount_2026].positive? ? "NEW" : "—"
    elsif row[:yoy_change].zero?
      "0.0%"
    else
      format("%+.1f%%", row[:yoy_rate])
    end
  end

  def yoy_color(row)
    return "#6c757d" if row[:amount_2025_ytd].zero? && row[:amount_2026].zero?
    row[:yoy_change].negative? ? "#c0392b" : "#1e7e34"
  end

  # 最近消費第二行：今天 / 1 天前 / N 天前 / 紅字 N 天沒消費
  def silent_days_label(days)
    return "今天" if days.zero?

    days > SpendingRankingsController::SILENT_DAYS ? "#{days} 天沒消費" : "#{days} 天前"
  end

  def silent_alert?(days)
    days.present? && days > SpendingRankingsController::SILENT_DAYS
  end

  # 排名變化：↑N / ↓N / 持平 / NEW / 回流 / 未進榜（以全量排名計算）
  def rank_delta_display(row)
    r25 = row[:rank_2025]
    r26 = row[:rank_2026]
    if r25 && r26
      diff = r25 - r26
      return ["持平", "#6c757d"] if diff.zero?

      diff.positive? ? ["↑ #{diff}", "#1e7e34"] : ["↓ #{diff.abs}", "#c0392b"]
    elsif r26
      row[:trend] == :returning ? %w[回流 #1a5da6] : %w[NEW #1a5da6]
    elsif r25
      ["未進榜", "#c0392b"]
    else
      ["—", "#6c757d"]
    end
  end

  def trend_badge(trend)
    case trend
    when :cooling   then ["流失警訊", "#fdecea", "#c0392b", "fa-arrow-down"]
    when :surpassed then ["超越去年", "#e6f4ea", "#1e7e34", "fa-arrow-up"]
    when :new       then ["NEW", "#e7f1fb", "#1a5da6", "fa-sparkles"]
    when :returning then ["回流", "#fdf3e7", "#b3641d", "fa-undo"]
    else                 ["穩定", "#f1f3f5", "#6c757d", nil]
    end
  end

  def sr_ig_link_url(account)
    return nil if account.blank?

    handle = account.strip.gsub(/^@/, "").gsub(%r{https?://(?:www\.)?instagram\.com/?}, "").gsub(%r{/$}, "").strip
    handle.present? ? "https://www.instagram.com/#{handle}/" : nil
  end

  def nt(amount)
    "NT$#{number_with_delimiter(amount)}"
  end

  # 帶正負號的金額差：+NT$1,880,640 / -NT$45,730
  def signed_nt(amount)
    "#{amount.negative? ? '-' : '+'}NT$#{number_with_delimiter(amount.abs)}"
  end
end
