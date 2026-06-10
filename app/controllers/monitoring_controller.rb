class MonitoringController < ApplicationController
  def index
    days = (params[:days] || 30).to_i
    since = days.days.ago

    # 各頁面造訪次數
    counts = PageView.where("visited_at >= ?", since)
      .group(:controller_name, :action_name)
      .count
      .transform_keys { |c, a| "#{c}##{a}" }

    # 整理成帶有 label 的列表，按造訪數排序
    @pages = PageView::ALL_TRACKED_PAGES.map do |key, label|
      { key: key, label: label, count: counts[key] || 0 }
    end.sort_by { |p| -p[:count] }

    @never_visited = @pages.select { |p| p[:count].zero? }
    @active_pages  = @pages.reject { |p| p[:count].zero? }
    @total_visits  = counts.values.sum
    @days          = days

    # 每日趨勢（最近 days 天）
    @daily_trend = PageView.where("visited_at >= ?", since)
      .group("DATE(visited_at)")
      .count
      .sort
      .map { |date, count| { date: date.to_s, count: count } }

    # 本日 / 本週
    @today_visits = PageView.where("visited_at >= ?", Date.today.beginning_of_day).count
    @week_visits  = PageView.where("visited_at >= ?", 7.days.ago).count

    # 客戶編輯軌跡
    @edit_logs = CustomerEditLog
      .order(created_at: :desc)
      .limit(100)
  end
end
