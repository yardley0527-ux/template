# frozen_string_literal: true

# 首頁風險條：規則式警示（不含 AI 判斷）。每條回傳
# { level: "danger"|"warning", message: }
#
# 規則：
# 1. 部門連續兩個「回報日」沒回報（以全公司有回報的日子當基準，避開週末假日）
# 2. 直播「品項未定」且倒數 ≤ 30 天
# 3. 未來 14 天有直播的產品目前標記缺貨（JourneyProducts.in_stock，手動維護）
# 4. 缺貨產品的補貨日（restock_date）晚於直播日
# 5. 直播倒數 ≤ 3 天，核心製作部門（設計/廣告/社群）近 3 天無相關提及
class OpsRiskScan
  UNDECIDED_WINDOW  = 30
  STOCK_WINDOW      = 14
  CORE_PREP_DEPTS   = %w[設計部 廣告部 社群部].freeze

  def self.call(radar: nil)
    new(radar: radar).call
  end

  def initialize(radar:)
    @radar = radar
  end

  def call
    risks = []
    risks.concat(silent_department_risks)
    risks.concat(undecided_livestream_risks)
    risks.concat(stock_conflict_risks)
    risks.concat(silent_core_dept_risks)
    risks
  end

  private

  # ── 規則 1：連兩個回報日無回報 ──
  def silent_department_risks
    report_days = DepartmentUpdate.where(log_date: ..Date.current)
                                  .distinct.order(log_date: :desc).limit(2).pluck(:log_date)
    return [] if report_days.size < 2

    reported = DepartmentUpdate.where(log_date: report_days)
                               .group(:department).count
    DepartmentUpdate::DEPARTMENTS.filter_map do |dept|
      next if reported[dept].to_i.positive?

      { level: "warning",
        message: "#{dept}已連續 2 個回報日（#{report_days.min.strftime('%-m/%-d')}–#{report_days.max.strftime('%-m/%-d')}）沒有日誌" }
    end
  end

  # ── 規則 2：品項未定倒數 ──
  def undecided_livestream_risks
    CalendarEvent.where(event_type: "livestream")
                 .where(event_date: Date.current..(Date.current + UNDECIDED_WINDOW))
                 .where("title LIKE ?", "%品項未定%")
                 .order(:event_date)
                 .map do |event|
      days = (event.event_date - Date.current).to_i
      { level: "warning",
        message: "#{event.event_date.strftime('%-m/%-d')} 直播品項未定（倒數 #{days} 天），請儘早在年度行事曆 Excel 補上" }
    end
  end

  # ── 規則 3＋4：缺貨 × 直播 ──
  def stock_conflict_risks
    upcoming = CalendarEvent.where(event_type: "livestream")
                            .where(event_date: Date.current..(Date.current + STOCK_WINDOW))
    upcoming.flat_map do |event|
      stock_entries_for(event.title).filter_map do |product|
        restock = product[:restock_date]
        if restock && restock > event.event_date
          { level: "danger",
            message: "#{event.event_date.strftime('%-m/%-d')} 直播「#{product[:label]}」補貨日 #{restock.strftime('%-m/%-d')} 晚於直播日" }
        elsif product[:in_stock] == false && restock.nil?
          { level: "danger",
            message: "#{event.event_date.strftime('%-m/%-d')} 直播「#{product[:label]}」目前標記缺貨且無補貨日" }
        end
      end
    end
  end

  # title 對到 JourneyProducts（手動維護的庫存旗標）
  def stock_entries_for(title)
    JourneyProducts::PRODUCTS.values.select { |p| title.include?(p[:label]) || title.include?(p[:short]) }
  end

  # ── 規則 5：倒數 3 天核心部門無動靜（吃雷達結果） ──
  def silent_core_dept_risks
    return [] if @radar.nil?

    days = (@radar[:livestream].event_date - Date.current).to_i
    return [] if days > 3 || @radar[:products].empty?

    @radar[:departments].filter_map do |entry|
      next unless CORE_PREP_DEPTS.include?(entry[:department])
      next if entry[:mentions].positive?

      { level: "danger",
        message: "#{@radar[:livestream].event_date.strftime('%-m/%-d')} 直播倒數 #{days} 天，#{entry[:department]}近 3 天日誌沒有相關動靜" }
    end
  end
end
