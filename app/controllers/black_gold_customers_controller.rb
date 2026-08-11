# frozen_string_literal: true

# 黑金卡消費備註：讓老闆一眼看到本日／本週／本月回來消費的黑卡、金卡客人，
# 這次回購距上次多久、金額比上次多還是少，異常的自動標「特別注意」，
# 並可直接在頁面上記備註（誰要特別關注、聯繫過什麼）
class BlackGoldCustomersController < ApplicationController
  LEVELS = %w[黑卡 金卡].freeze

  DROP_RATIO    = 0.5 # 本次金額 < 上次 × 50% → 消費下滑
  LONG_GAP_DAYS = 90  # 距上次購買 >= 90 天 → 間隔拉長（沿用「黑金卡沉睡」通知門檻）

  ORDER_TOTAL_SQL = <<~SQL.squish.freeze
    CASE
      WHEN MAX(NULLIF(o.total_amount, 0)) IS NOT NULL THEN MAX(NULLIF(o.total_amount, 0))
      ELSE SUM(COALESCE(o.checkout_amount, 0))
    END
  SQL

  OrderTotal = Struct.new(:order_num, :email, :ord_date, :order_total, :products_list, keyword_init: true)

  Row = Struct.new(
    :shopline_customer_id, :full_name, :email, :ig_account, :membership_level,
    :current_date, :current_amount, :current_products,
    :previous_date, :previous_amount,
    :profile,
    keyword_init: true
  ) do
    def interval_days
      previous_date && (current_date.to_date - previous_date.to_date).to_i
    end

    def amount_diff
      previous_amount && (current_amount - previous_amount)
    end

    def amount_change_ratio
      previous_amount && previous_amount.positive? ? (current_amount - previous_amount) / previous_amount : nil
    end

    def first_time?
      previous_date.nil?
    end

    def dropped?
      previous_amount.present? && previous_amount.positive? && current_amount < previous_amount * BlackGoldCustomersController::DROP_RATIO
    end

    def long_gap?
      interval_days.present? && interval_days >= BlackGoldCustomersController::LONG_GAP_DAYS
    end

    def needs_attention?
      dropped? || long_gap?
    end

    # AI 分析是否還對得上「本次」訂單；客人之後又下單了，快取就算過期，要重新分析
    def ai_fresh?
      profile.present? && profile.black_gold_ai_generated_at.present? &&
        profile.black_gold_ai_for_order_date == current_date.to_date
    end
  end

  PERIODS = %w[today week month].freeze

  def index
    @period = PERIODS.include?(params[:period]) ? params[:period] : "today"

    @counts = PERIODS.index_with { |p| rows_for(p).size }
    rows = rows_for(@period)
    @attention_count = rows.count(&:needs_attention?)
    @groups = LEVELS.map { |level| [level, rows.select { |r| r.membership_level == level }] }
  end

  def upsert_note
    customer = ShoplineCustomer.find(params[:customer_id])
    profile  = customer.customer_profile || customer.build_customer_profile
    note     = params[:note].to_s
    profile.update!(
      black_gold_note: note,
      black_gold_note_edited_by: note.present? ? current_user.username : nil
    )

    head :ok
  end

  # 針對單一客人呼叫 AI 分析（消費軌跡＋CRM備註 → 要注意什麼／下一步行銷），
  # 特別注意名單頁面載入時前端會自動打這支，其餘客人由手動按鈕觸發
  def analyze
    customer = ShoplineCustomer.find(params[:customer_id])
    result   = BlackGoldCustomerInsightService.call(customer)

    if result[:ok]
      profile = result[:profile]
      render json: {
        ok: true,
        watch: profile.black_gold_ai_watch,
        next_actions: profile.black_gold_ai_next_actions,
        generated_at: profile.black_gold_ai_generated_at.strftime("%-m/%-d %H:%M")
      }
    else
      render json: { ok: false, error: result[:error] }, status: :unprocessable_entity
    end
  end

  private

  def period_range(period)
    case period
    when "today" then Time.zone.today.beginning_of_day..Time.zone.today.end_of_day
    when "week"  then Time.zone.today.beginning_of_week.beginning_of_day..Time.zone.today.end_of_day
    else              Time.zone.today.beginning_of_month.beginning_of_day..Time.zone.today.end_of_day
    end
  end

  def rows_for(period)
    @rows_cache ||= {}
    @rows_cache[period] ||= build_rows(period)
  end

  # 每位黑金卡客人：全部已付款訂單依日期排序，找出「本次」在期間內最新一筆，
  # 與其緊接的「上次」訂單（不限期間，只要是本次之前最近一筆），算出間隔與金額差
  def build_rows(period)
    range = period_range(period)
    orders_by_email = all_orders_by_email
    return [] if orders_by_email.empty?

    customers_by_email.filter_map do |email, customer|
      list = orders_by_email[email]
      next if list.blank?

      in_period = list.select { |o| o.ord_date >= range.first && o.ord_date <= range.last }
      next if in_period.empty?

      current  = in_period.last
      idx      = list.index(current)
      previous = idx.positive? ? list[idx - 1] : nil

      Row.new(
        shopline_customer_id: customer.id,
        full_name:            customer.full_name,
        email:                email,
        ig_account:           customer.instagram_account,
        membership_level:     customer.membership_level,
        current_date:         current.ord_date,
        current_amount:       current.order_total.to_f,
        current_products:     current.products_list,
        previous_date:        previous&.ord_date,
        previous_amount:      previous ? previous.order_total.to_f : nil,
        profile:              profiles_by_customer_id[customer.id]
      )
    end.sort_by { |r| -r.current_date.to_i }
  end

  def customers_by_email
    @customers_by_email ||= ShoplineCustomer.where(membership_level: LEVELS)
      .select(:id, :email, :full_name, :instagram_account, :membership_level)
      .index_by(&:email)
  end

  def profiles_by_customer_id
    @profiles_by_customer_id ||= CustomerProfile.where(shopline_customer_id: customers_by_email.values.map(&:id)).index_by(&:shopline_customer_id)
  end

  # build_rows 只需要每位客人「最新一筆」跟「上一筆」訂單，不需要整份歷史，
  # 用 window function 在 DB 端先篩到只剩每人最近 2 筆，避免把黑卡+金卡全部人的
  # 全部歷史訂單一次撈進 Rails process（這曾經在 Hobby plan 512MB 記憶體上限下
  # 把 instance 撐爆、被 Render 強制重啟，期間打進來的請求收到 502）
  def all_orders_by_email
    @all_orders_by_email ||= begin
      emails = customers_by_email.keys
      return {} if emails.empty?

      order_agg = ShoplineOrder.from("shopline_orders o")
        .where("o.email IN (?)", emails)
        .where("o.payment_status = '已付款'")
        .select(
          "o.order_number AS order_num",
          "MAX(o.email) AS email_val",
          "MAX(o.order_date) AS ord_date",
          "#{ORDER_TOTAL_SQL} AS order_total",
          "STRING_AGG(DISTINCT o.product_name, '、' ORDER BY o.product_name) AS products_list"
        )
        .group("o.order_number")

      # order_date 只有日期沒有時間，同一天多筆訂單會打平；order_number 是固定寬度的
      # 時間戳格式（"#" + 17 碼），拿來當第二排序鍵可以還原同一天內的實際先後順序
      ranked_sql = <<~SQL
        SELECT * FROM (
          SELECT agg.*, ROW_NUMBER() OVER (PARTITION BY email_val ORDER BY ord_date DESC, order_num DESC) AS rn
          FROM (#{order_agg.to_sql}) agg
        ) ranked
        WHERE rn <= 2
      SQL

      raw = ShoplineOrder.find_by_sql(ranked_sql)
      raw.group_by(&:email_val).transform_values { |list| list.sort_by { |o| [o.ord_date, o.order_num] } }
    end
  end
end
