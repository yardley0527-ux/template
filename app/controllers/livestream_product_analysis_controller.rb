# frozen_string_literal: true

# 方案 B PR4：共用產品直播分析頁，取代 5 個各自為政的舊 controller
# （omnipotent/probiotic/turmeric/metabolism/glutathione_analysis）。
# 用 ?product= 切換 13 個 crm_products，不再為每個產品開一個 controller/view。
class LivestreamProductAnalysisController < ApplicationController
  include MembershipLevels

  CROSS_SELL_RULES = {
    "omnipotent" => { target_key: "whitening", target_label: "美白" }
  }.freeze

  before_action :set_product
  before_action :build_analytics

  def index
    build_special_modules
  end

  def export_missing
    send_data "\xEF\xBB\xBF" + missing_csv,
              filename: "#{@product_label}_未回購名單_#{Date.current}.csv",
              type: "text/csv; charset=utf-8"
  end

  def export_event
    send_data "\xEF\xBB\xBF" + event_csv,
              filename: "#{@product_label}_最新場買家名單_#{Date.current}.csv",
              type: "text/csv; charset=utf-8"
  end

  def export_action
    build_special_modules
    send_data "\xEF\xBB\xBF" + action_csv,
              filename: "#{@product_label}_行動清單_#{Date.current}.csv",
              type: "text/csv; charset=utf-8"
  end

  private

  def set_product
    @product_options = CrmProduct.for_analysis.order(:label).pluck(:key, :label)
    @product_key = params[:product].presence || @product_options.first&.first
    @product_label = @product_options.to_h[@product_key] || @product_key
  end

  def build_analytics
    @analytics = ProductLivestreamAnalytics.new(@product_key)
    @cross_event_stats = @analytics.cross_event_stats
    @latest_event = @analytics.latest_event
    @iron_fans = @analytics.iron_fans
    @high_risk_lost = @analytics.high_risk_lost
    @missing_customers = @analytics.missing_customers
    @expiring_soon = @analytics.expiring_soon
    @level_attendance = @analytics.level_attendance
    @recognition_coverage = @analytics.recognition_coverage
    @bundle_components_decomposed = @analytics.bundle_components_decomposed?
  end

  def build_special_modules
    case @product_key
    when "probiotic"
      build_probiotic_module
    when "omnipotent"
      build_cross_sell_module
    end
  end

  def build_probiotic_module
    @sku_by_event = @analytics.event_summaries.map do |s|
      ls = s[:livestream]
      range = LivestreamAttribution.window_range(ls.date, ls.window_days)
      rows = ProductNameResolver.orders_for(@product_key).where(order_date: range)
                                 .where.not(email: [nil, ""])
                                 .pluck(:product_name, :email, :checkout_amount, :total_amount)
      grouped = rows.group_by { |pname, _e, _c, _t| pname }
      skus = grouped.map do |pname, entries|
        buyers = entries.map { |_, e, _, _| e }.uniq.size
        revenue = entries.sum { |_, _, c, t| (t.to_f.nonzero? || c.to_f) }.to_i
        { product_name: pname, boxes: BottleExtractor.call(pname, @product_key), buyers: buyers, orders: entries.size, revenue: revenue }
      end.sort_by { |s2| s2[:boxes] }
      total_rev = skus.sum { |s2| s2[:revenue] }
      skus.each { |s2| s2[:rev_pct] = total_rev.positive? ? (s2[:revenue].to_f / total_rev * 100).round(1) : 0.0 }
      { livestream: ls, skus: skus, total_buyers: rows.map { |_, e, _, _| e }.uniq.size, total_orders: rows.size, total_revenue: total_rev }
    end

    @action_list = build_action_list
  end

  # 把「快用完」「黑金流失」「本場未回購」三份名單合併，同一人只出現一次、
  # 附上全部理由，依最急迫理由排序（沿用舊 ProbioticAnalysisController 邏輯）。
  def build_action_list
    entries = {}
    add_reason = lambda do |customer, rank, badge, detail|
      entry = entries[customer.id] ||= { customer: customer, reasons: [], best_rank: 999 }
      entry[:reasons] << { badge: badge, detail: detail }
      entry[:best_rank] = rank if rank < entry[:best_rank]
    end

    @expiring_soon.each do |r|
      c = r[:customer]
      dl = r[:days_left]
      rank, badge = if dl.negative?
                      [1, "🧴 已用完 #{dl.abs} 天"]
                    elsif dl <= 7
                      [4, "🧴 剩 #{dl} 天用完"]
                    else
                      [6, "🧴 剩 #{dl} 天用完"]
                    end
      add_reason.call(c, rank, badge, "上次買 #{r[:last_product]}（#{r[:last_date]&.strftime('%m/%d')}）")
    end

    @high_risk_lost.each do |r|
      c = r[:customer]
      add_reason.call(c, 2, "🚨 #{c.membership_level}流失", "曾出席 #{r[:attended_labels].join('、')}，最近一場沒來")
    end

    @missing_customers.each do |r|
      c = r[:customer]
      rank = r[:overdue_days] && r[:overdue_days] > 14 ? 3 : 5
      add_reason.call(c, rank, "📦 本場未回購（逾 #{r[:overdue_days]} 天）", "上次買 #{r[:last_product]}（#{r[:last_date]&.strftime('%m/%d')}）")
    end

    entries.values.sort_by { |e| [e[:best_rank], -MEMBERSHIP_RANK.fetch(e[:customer].membership_level, 0)] }
  end

  def build_cross_sell_module
    rule = CROSS_SELL_RULES[@product_key]
    return unless rule

    @cross_sell_target_label = rule[:target_label]
    @cross_sell_buyers = @analytics.cross_sell(target_key: rule[:target_key])
    @ig_discount = IgDiscountCohortLookup
  end

  def action_csv
    require "csv"
    CSV.generate(encoding: "UTF-8") do |csv|
      csv << ["#", "姓名", "卡別", "聯絡理由", "IG"]
      (@action_list || []).each_with_index do |e, i|
        c = e[:customer]
        reasons = e[:reasons].map { |r| "#{r[:badge]} #{r[:detail]}" }.join(" | ")
        csv << [i + 1, c.full_name, c.membership_level, reasons, c.instagram_account]
      end
    end
  end

  def missing_csv
    require "csv"
    CSV.generate(encoding: "UTF-8") do |csv|
      csv << ["姓名", "卡別", "電話", "上次購買#{@product_label}", "購買瓶數", "逾期天數", "歷史次數", "歷史消費(NT$)", "IG"]
      @missing_customers.each do |r|
        c = r[:customer]
        csv << [c.full_name, c.membership_level, c.mobile_phone,
                r[:last_date]&.strftime("%Y/%m/%d"), r[:bottles], r[:overdue_days], r[:history_count], r[:history_amount].to_i, c.instagram_account]
      end
    end
  end

  def event_csv
    require "csv"
    CSV.generate(encoding: "UTF-8") do |csv|
      csv << ["姓名", "卡別", "電話", "IG"]
      if @latest_event
        emails = @analytics.event_summaries.last[:emails]
        ShoplineCustomer.where(email: emails.to_a).find_each do |c|
          csv << [c.full_name, c.membership_level, c.mobile_phone, c.instagram_account]
        end
      end
    end
  end
end
