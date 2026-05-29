class OmnipotentAnalysisController < ApplicationController
  include ProductLivestreamAnalysis

  self.product_sql        = "product_name LIKE '%全能%'"
  self.product_label      = "全能"
  self.product_regex      = /全能(\d+)/
  self.product_event_list = LivestreamAnalysisController::ALL_EVENTS
    .select { |e| e[:note]&.include?("全能") }.freeze

  # 保留給 export_whitening 使用（before_action :build_analysis_data 來自 concern）
  before_action :build_whitening_data, only: [:export_whitening]

  OMNI_EVENTS = product_event_list

  def index
    @all_omni_events = product_event_list.select { |e| e[:date] <= Date.today }
    build_comprehensive_data(@all_omni_events)
  end

  def export_whitening
    send_data "\xEF\xBB\xBF" + whitening_csv,
              filename: "全能×美白_交叉推薦名單_#{Date.today}.csv",
              type: "text/csv; charset=utf-8"
  end

  private

  def build_whitening_data
    @all_omni_events = product_event_list.select { |e| e[:date] <= Date.today }
    build_comprehensive_data(@all_omni_events)
  end

  def build_comprehensive_data(all_events)
    return if all_events.empty?

    window_start = all_events.first[:date].beginning_of_day
    window_end   = (all_events.last[:date] + 3).end_of_day

    all_omni_rows = ShoplineOrder.where(product_sql)
      .where(order_date: window_start..window_end)
      .where.not(email: [nil, ""])
      .pluck(:email, :order_date, :checkout_amount, :total_amount)

    all_event_emails = all_events.map do |ev|
      range = ev[:date].beginning_of_day..(ev[:date] + 3).end_of_day
      all_omni_rows.filter_map { |email, date, _, _| email if range.cover?(date) }.uniq
    end

    omni_revenues = all_events.map do |ev|
      range = ev[:date].beginning_of_day..(ev[:date] + 3).end_of_day
      all_omni_rows.select { |_, date, _, _| range.cover?(date) }
                   .sum { |_, _, checkout, total| (checkout || total).to_f }
    end

    @cross_event_stats = all_events.each_with_index.map do |ev, i|
      emails   = all_event_emails[i]
      prev     = i > 0 ? all_event_emails[i - 1] : []
      overlap  = (prev & emails).size
      end_date = ev[:date] + 3
      rev      = omni_revenues[i].to_i
      {
        label:          "#{ev[:year]}/#{ev[:label]}~#{end_date.month}/#{end_date.day}",
        note:           ev[:note],
        single_product: ev[:note].split(/[、,+＋]/).map(&:strip).one? { |p| p.include?("全能") },
        buyers:         emails.size,
        revenue:        rev,
        aov:            (emails.size > 0 && rev > 0) ? (rev / emails.size) : 0,
        return_rate:    prev.any? ? pct(overlap, prev.size) : nil,
        return_count:   prev.any? ? overlap : nil
      }
    end

    all_emails = all_event_emails.flatten.uniq
    today      = Date.today

    last_orders_raw = ShoplineOrder.where(product_sql).where(email: all_emails)
      .order(:email, order_date: :desc).pluck(:email, :product_name, :order_date)

    last_by_email = {}
    last_orders_raw.each { |e, p, d| last_by_email[e] ||= { product_name: p, order_date: d } }

    @expiring_soon = ShoplineCustomer.where(email: all_emails)
      .select(:id, :full_name, :email, :mobile_phone, :membership_level, :instagram_account)
      .filter_map do |c|
        last = last_by_email[c.email]
        next unless last
        bottles   = extract_bottles(last[:product_name])
        last_date = last[:order_date].to_date
        days_left = (bottles * ProductLivestreamAnalysis::DAYS_PER_BOTTLE) - (today - last_date).to_i
        next unless days_left >= -7 && days_left <= 21
        { customer: c, days_left: days_left, last_product: last[:product_name], last_date: last_date }
      end.sort_by { |r| [r[:days_left], -ProductLivestreamAnalysis::MEMBERSHIP_RANK.fetch(r[:customer].membership_level, 0)] }

    iron_emails = all_event_emails.reduce(:&)
    @iron_fans  = ShoplineCustomer.where(email: iron_emails)
      .select(:id, :full_name, :email, :mobile_phone, :membership_level, :instagram_account, :total_amount)
      .map { |c| { customer: c, attended_count: all_events.size } }
      .sort_by { |r| [-ProductLivestreamAnalysis::MEMBERSHIP_RANK.fetch(r[:customer].membership_level, 0), -r[:customer].total_amount.to_f] }

    latest_emails = all_event_emails.last
    lost_emails   = all_event_emails[0..-2].flatten.uniq - latest_emails
    @high_risk_lost = ShoplineCustomer
      .where(email: lost_emails).where(membership_level: %w[黑卡 金卡])
      .select(:id, :full_name, :email, :mobile_phone, :membership_level, :instagram_account, :total_amount)
      .map do |c|
        attended = all_events[0..-2].each_with_index
          .select { |_, i| all_event_emails[i].include?(c.email) }
          .map { |ev, _| "#{ev[:year]}/#{ev[:label]}" }
        { customer: c, attended_labels: attended }
      end.sort_by { |r| [-ProductLivestreamAnalysis::MEMBERSHIP_RANK.fetch(r[:customer].membership_level, 0), -r[:customer].total_amount.to_f] }

    # 美白交叉推薦（全能專屬邏輯）
    event_windows_sql    = all_events.map { "(order_date BETWEEN ? AND ?)" }.join(" OR ")
    event_windows_params = all_events.flat_map { |ev| [ev[:date].beginning_of_day, (ev[:date] + 3).end_of_day] }

    whitening_at_event_emails = ShoplineOrder
      .where("product_name LIKE '%美白%'")
      .where(event_windows_sql, *event_windows_params)
      .where.not(email: [nil, ""]).distinct.pluck(:email)

    last_event_end     = (all_events.last[:date] + 3).end_of_day
    rebought_whitening = ShoplineOrder.where("product_name LIKE '%美白%'")
      .where("order_date > ?", last_event_end)
      .where.not(email: [nil, ""]).distinct.pluck(:email)

    lapsed_whitening_emails = whitening_at_event_emails - rebought_whitening

    omni_count_by_email = all_emails.index_with { |email|
      all_event_emails.count { |ev_emails| ev_emails.include?(email) }
    }

    @whitening_cross_buyers = ShoplineCustomer
      .where(email: lapsed_whitening_emails).where(membership_level: %w[黑卡 金卡])
      .select(:id, :full_name, :email, :mobile_phone, :membership_level, :instagram_account, :total_amount)
      .map { |c| { customer: c, omni_count: omni_count_by_email[c.email] || 0 } }
      .sort_by { |r| [-ProductLivestreamAnalysis::MEMBERSHIP_RANK.fetch(r[:customer].membership_level, 0), -r[:customer].total_amount.to_f] }
  end

  def whitening_csv
    require "csv"
    CSV.generate(encoding: "UTF-8") do |csv|
      csv << ["姓名", "卡別", "電話", "全能購買場次數", "整體消費力(NT$)", "IG"]
      @whitening_cross_buyers.each do |r|
        c = r[:customer]
        csv << [c.full_name, c.membership_level, c.mobile_phone,
                r[:omni_count], c.total_amount.to_i, c.instagram_account]
      end
    end
  end

  def event_csv
    require "csv"
    CSV.generate(encoding: "UTF-8") do |csv|
      csv << ["客戶價值", "姓名", "卡別", "電話", "購買品項", "本次瓶數", "本次金額(NT$)", "整體消費力(NT$)", "全能歷史次數", "IG"]
      @event_customers.each do |r|
        c = r[:customer]
        csv << [r[:value_tier], c.full_name, c.membership_level, c.mobile_phone,
                r[:last_product], r[:bottles], r[:order_amount].to_i,
                r[:total_spend].to_i, r[:product_count], c.instagram_account]
      end
    end
  end
end
