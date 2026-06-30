class OmnipotentAnalysisController < ApplicationController
  include ProductLivestreamAnalysis

  self.product_key        = "omnipotent"   # Epic C Phase 2: Registry-driven (0 diff vs LIKE ✓)
  self.product_label      = "全能"
  self.product_event_list = LivestreamAnalysisController::ALL_EVENTS
    .select { |e| e[:note]&.include?("全能") }.freeze

  # 保留給 export_whitening 使用（before_action :build_analysis_data 來自 concern）
  before_action :build_whitening_data, only: [:export_whitening]

  OMNI_EVENTS = product_event_list

  IG_DISCOUNT_CODES = [
    { code: "ST50",  group: "官方IG折扣碼",  name: "古怡文",             email: "evitaguu@gmail.com",          amount: 29_650, level: "黑卡",   used_at: "2026-06-05 22:00" },
    { code: "ST50",  group: "官方IG折扣碼",  name: "鄭乃嘉",             email: "heroicshoes@hotmail.com",      amount: 18_910, level: "黑卡",   used_at: "2026-06-05 20:40" },
    { code: "ST50",  group: "官方IG折扣碼",  name: "蕭郁璇",             email: "kina11141114@yahoo.com.tw",    amount: 20_790, level: "金卡",   used_at: "2026-06-05 22:35" },
    { code: "ST50",  group: "官方IG折扣碼",  name: "李鈺慧",             email: "amy5237@gmail.com",            amount: 20_470, level: "金卡",   used_at: "2026-06-05 23:55" },
    { code: "ST50",  group: "官方IG折扣碼",  name: "曾楨雯",             email: "jessica7075@gmail.com",        amount: 20_690, level: "銀卡",   used_at: "2026-06-05 23:29" },
    { code: "ST50",  group: "官方IG折扣碼",  name: "weiyuping",          email: "weiwei801204@gmail.com",       amount:  6_250, level: "白卡",   used_at: "2026-06-04 22:05" },
    { code: "ST50",  group: "官方IG折扣碼",  name: "黃楷婷",             email: "renee80118@gmail.com",         amount:  3_450, level: "白卡",   used_at: "2026-06-05 21:57" },
    { code: "ST50",  group: "官方IG折扣碼",  name: "Bridget C.",         email: "bee1814@yahoo.com.tw",         amount: 14_830, level: "新客",   used_at: "2026-06-05 21:12" },
    { code: "ST100", group: "全能IG折扣碼", name: "阿甄",               email: "seeyou78628@gmail.com",        amount: 22_620, level: "黑卡",   used_at: "2026-06-06 00:36" },
    { code: "ST100", group: "全能IG折扣碼", name: "郭盈華",             email: "e3150009@gmail.com",            amount: 20_500, level: "黑卡",   used_at: "2026-06-06 00:01" },
    { code: "ST100", group: "全能IG折扣碼", name: "囍兒",               email: "love05171103@yahoo.com.tw",    amount: 29_600, level: "黑卡",   used_at: "2026-06-05 23:41" },
    { code: "ST100", group: "全能IG折扣碼", name: "Ginny",              email: "fan21963@hotmail.com",          amount: 18_860, level: "黑卡",   used_at: "2026-06-05 21:54" },
    { code: "ST100", group: "全能IG折扣碼", name: "珮茹",               email: "karen.apr16@icloud.com",       amount: 31_240, level: "黑卡",   used_at: "2026-06-05 21:51" },
    { code: "ST100", group: "全能IG折扣碼", name: "Shuhan Chang",       email: "angel_10263@hotmail.com",      amount: 16_860, level: "金卡",   used_at: "2026-06-07 18:35" },
    { code: "ST100", group: "全能IG折扣碼", name: "曾齡億",             email: "a0101bebe@gmail.com",           amount: 20_740, level: "金卡",   used_at: "2026-06-07 12:52" },
    { code: "ST100", group: "全能IG折扣碼", name: "馮嘉瑄",             email: "fcy1979@gmail.com",             amount: 26_300, level: "金卡",   used_at: "2026-06-09 12:43" },
    { code: "ST100", group: "全能IG折扣碼", name: "江美儀",             email: "m172667@yahoo.com.tw",          amount: 29_600, level: "銀卡",   used_at: "2026-06-06 17:53" },
    { code: "ST100", group: "全能IG折扣碼", name: "許靜宜",             email: "vivihsu0923@gmail.com",         amount: 14_980, level: "銀卡",   used_at: "2026-06-06 13:08" },
    { code: "ST100", group: "全能IG折扣碼", name: "曾楨雯",             email: "jessica7075@gmail.com",        amount: 20_690, level: "銀卡",   used_at: "2026-06-05 23:29" },
    { code: "ST100", group: "全能IG折扣碼", name: "謝孟庭",             email: "mtq517783@gmail.com",           amount: 20_420, level: "銀卡",   used_at: "2026-06-05 21:34" },
    { code: "ST100", group: "全能IG折扣碼", name: "陳孟君",             email: "eleanquin@hotmail.com",         amount:  8_300, level: "白卡",   used_at: "2026-06-06 05:13" },
    { code: "ST100", group: "全能IG折扣碼", name: "王嘉雯",             email: "a63281688@yahoo.com.tw",        amount: 20_560, level: "白卡",   used_at: "2026-06-05 23:33" },
    { code: "ST100", group: "全能IG折扣碼", name: "YiHsuan Li",        email: "lemonrabit@gmail.com",           amount: 18_860, level: "白卡",   used_at: "2026-06-05 23:17" },
    { code: "ST100", group: "全能IG折扣碼", name: "林育鈴",             email: "pipibetty0325@gmail.com",       amount: 14_980, level: "白卡",   used_at: "2026-06-05 23:13" },
    { code: "ST100", group: "全能IG折扣碼", name: "楊采潔",             email: "katelovedong@gmail.com",        amount: 29_600, level: "白卡",   used_at: "2026-06-05 21:35" },
    { code: "ST100", group: "全能IG折扣碼", name: "陳佳宜",             email: "spy2609@yahoo.com.tw",          amount:  8_300, level: "一般",   used_at: "2026-06-06 22:40" },
    { code: "ST100", group: "全能IG折扣碼", name: "林千彙",             email: "aaron89092349@gmail.com",       amount: 29_600, level: "一般",   used_at: "2026-06-05 22:01" },
    { code: "ST100", group: "全能IG折扣碼", name: "林于婷",             email: "in35012@yahoo.com.tw",          amount: 29_600, level: "一般",   used_at: "2026-06-05 21:39" },
    { code: "ST100", group: "全能IG折扣碼", name: "廖珮孜",             email: "s06240824@yahoo.com.tw",        amount: 14_980, level: "一般",   used_at: "2026-06-08 14:49" },
  ].freeze

  def index
    @all_omni_events = product_event_list.select { |e| e[:date] <= Date.today }
    build_comprehensive_data(@all_omni_events)
    build_ig_discount_data
  end

  def export_whitening
    send_data "\xEF\xBB\xBF" + whitening_csv,
              filename: "全能×美白_交叉推薦名單_#{Date.today}.csv",
              type: "text/csv; charset=utf-8"
  end

  private

  def build_ig_discount_data
    emails = IG_DISCOUNT_CODES.map { |r| r[:email] }.uniq
    history_counts = ShoplineOrder.where("product_name LIKE '%全能%'")
      .where(email: emails).group(:email).count
    customer_map = ShoplineCustomer.where(email: emails)
      .index_by(&:email)

    @ig_discount_rows = IG_DISCOUNT_CODES.map do |r|
      c = customer_map[r[:email]]
      {
        code:          r[:code],
        group:         r[:group],
        name:          r[:name],
        email:         r[:email],
        amount:        r[:amount],
        level:         r[:level],
        used_at:       r[:used_at],
        history_count: history_counts[r[:email]] || 0,
        customer_id:   c&.id
      }
    end

    @ig_st50  = @ig_discount_rows.select { |r| r[:code] == "ST50" }
    @ig_st100 = @ig_discount_rows.select { |r| r[:code] == "ST100" }
  end

  def build_whitening_data
    @all_omni_events = product_event_list.select { |e| e[:date] <= Date.today }
    build_comprehensive_data(@all_omni_events)
  end

  def after_build_comprehensive_data(all_events:, all_event_emails:, all_emails:)
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
      .sort_by { |r| [-MEMBERSHIP_RANK.fetch(r[:customer].membership_level, 0), -r[:customer].total_amount.to_f] }
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
                r[:total_spend].to_i, r[:omni_count], c.instagram_account]
      end
    end
  end
end
