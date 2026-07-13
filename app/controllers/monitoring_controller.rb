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

    # 各用戶頁面使用統計
    raw_user_stats = PageView.where("visited_at >= ?", since)
      .where.not(user_id: nil)
      .group(:user_id, :controller_name, :action_name)
      .count

    user_ids = raw_user_stats.keys.map(&:first).uniq
    users    = User.where(id: user_ids).index_by(&:id)

    @user_page_stats = raw_user_stats.map do |(user_id, ctrl, act), count|
      user      = users[user_id]
      user_label = user&.username || user&.email&.split("@")&.first || "—"
      page_key  = "#{ctrl}##{act}"
      page_label = PageView::ALL_TRACKED_PAGES[page_key] || page_key
      { user: user_label, page: page_label, key: page_key, count: count }
    end.sort_by { |r| [r[:user], -r[:count]] }

    # 客戶編輯軌跡
    @edit_logs = CustomerEditLog
      .order(created_at: :desc)
      .limit(20)

    @home_adoption = build_home_adoption
  end

  private

  # 戰情首頁開啟率：P0 的成敗指標（上線兩週後看管理者每週開幾天）。
  # 每人每天算一次，最近 14 天。
  def build_home_adoption
    since = 13.days.ago.to_date
    rows = PageView.where(controller_name: "welcome", action_name: "index")
                   .where("visited_at >= ?", since.beginning_of_day)
                   .where.not(user_id: nil)
                   .group(:user_id, Arel.sql("DATE(visited_at)"))
                   .count

    users = User.where(id: rows.keys.map(&:first).uniq).index_by(&:id)
    by_user = Hash.new { |h, k| h[k] = Set.new }
    rows.each_key do |(user_id, date)|
      label = users[user_id]&.username || "user##{user_id}"
      by_user[label] << date.to_date
    end

    dates = (since..Date.current).to_a
    {
      dates: dates,
      users: by_user.map { |name, days| { name: name, days: days, total: days.size } }
                    .sort_by { |u| -u[:total] }
    }
  end
end
