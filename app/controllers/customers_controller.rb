# frozen_string_literal: true

class CustomersController < ApplicationController
  PER_PAGE = 20
  MAX_PAGE = 200

  # 卡別成長人工對照表：卡別每日快照 2026/08/17 才上線（見 MembershipLevelSnapshot），
  # 目前只有 1 天資料，無法自動算出「今年 vs 去年」。這份數字整理自使用者提供的
  # Shopline 後台儀表板截圖（非本站資料庫查詢），累積滿一年後這個區塊可以拿掉，
  # 改成完全吃 MembershipLevelSnapshot 的即時計算。
  MEMBERSHIP_MANUAL_REFERENCE = {
    updated_at: "2026/08/17",
    snapshot_at: "2026/08/16",
    new_customers: {
      rows: [
        { label: "2025/01 起始",     customers: 6_161,  paying_customers: 4_317, paying_members: 4_300, non_paying_members: 1_850 },
        { label: "2025/12 年底",     customers: 9_197,  paying_customers: 6_568, paying_members: 6_558, non_paying_members: 2_621 },
        { label: "2025 全年淨增",    customers: 3_036,  paying_customers: 2_251, paying_members: 2_258, non_paying_members: 771, is_delta: true },
        { label: "2026/01 起始",     customers: 9_297,  paying_customers: 6_656, paying_members: 6_645, non_paying_members: 2_633 },
        { label: "2026/08/16 至今",  customers: 10_475, paying_customers: 7_586, paying_members: 7_556, non_paying_members: 2_880 },
        { label: "2026 年初至今淨增", customers: 1_178, paying_customers: 930,   paying_members: 911,   non_paying_members: 247, is_delta: true },
      ]
    },
    tiers_2025_full_year: [
      { level: "黑卡", from: 14,  to: 72,  delta: 58,  pct: 414.3 },
      { level: "金卡", from: 98,  to: 239, delta: 141, pct: 143.9 },
      { level: "銀卡", from: 320, to: 467, delta: 147, pct: 45.9 },
      { level: "白卡", from: 833, to: 996, delta: 163, pct: 19.6 },
      { level: "一般會員", from: 4_885, to: 7_405, delta: 2_520, pct: 51.6 },
    ],
    tiers_2026_ytd_vs_2025_full_year: [
      { level: "一般會員", y2025_start: 4_885, y2025_end: 7_405, y2025_delta: 2_520, y2025_pct: 51.6,
        y2026_start: 7_570, y2026_end: 9_084, y2026_delta: 1_514, y2026_pct: 20.0 },
      { level: "白卡", y2025_start: 833, y2025_end: 996, y2025_delta: 163, y2025_pct: 19.6,
        y2026_start: 961, y2026_end: 771, y2026_delta: -190, y2026_pct: -19.8 },
      { level: "銀卡", y2025_start: 320, y2025_end: 467, y2025_delta: 147, y2025_pct: 45.9,
        y2026_start: 445, y2026_end: 335, y2026_delta: -110, y2026_pct: -24.7 },
      { level: "金卡", y2025_start: 98, y2025_end: 239, y2025_delta: 141, y2025_pct: 143.9,
        y2026_start: 224, y2026_end: 169, y2026_delta: -55, y2026_pct: -24.6 },
      { level: "黑卡", y2025_start: 14, y2025_end: 72, y2025_delta: 58, y2025_pct: 414.3,
        y2026_start: 78, y2026_end: 77, y2026_delta: -1, y2026_pct: -1.3 },
    ],
    tiers_jan_to_jul_yoy: [
      { level: "一般會員", y2025_start: 4_885, y2025_end: 6_797, y2025_delta: 1_912, y2025_pct: 39.1,
        y2026_start: 7_570, y2026_end: 8_960, y2026_delta: 1_390, y2026_pct: 18.4 },
      { level: "白卡", y2025_start: 833, y2025_end: 1_004, y2025_delta: 171, y2025_pct: 20.5,
        y2026_start: 961, y2026_end: 794, y2026_delta: -167, y2026_pct: -17.4 },
      { level: "銀卡", y2025_start: 320, y2025_end: 465, y2025_delta: 145, y2025_pct: 45.3,
        y2026_start: 445, y2026_end: 338, y2026_delta: -107, y2026_pct: -24.0 },
      { level: "金卡", y2025_start: 98, y2025_end: 187, y2025_delta: 89, y2025_pct: 90.8,
        y2026_start: 224, y2026_end: 180, y2026_delta: -44, y2026_pct: -19.6 },
      { level: "黑卡", y2025_start: 14, y2025_end: 40, y2025_delta: 26, y2025_pct: 185.7,
        y2026_start: 78, y2026_end: 81, y2026_delta: 3, y2026_pct: 3.8 },
    ]
  }.freeze

  AGE_GROUP_ORDER = ["未滿 25", "25–29", "30–34", "35–39", "40–44", "45 以上"].freeze
  ZODIAC_ORDER    = %w[牡羊 金牛 雙子 巨蟹 獅子 處女 天秤 天蠍 射手 摩羯 水瓶 雙魚].freeze

  def index
    @q                = params[:q].to_s.strip
    @membership_level = params[:membership_level].to_s.strip
    @min_credits      = to_number(params[:min_credits])
    @sort             = params[:sort].to_s.strip.presence || "amount_desc"
    @zodiac           = params[:zodiac].to_s.strip
    @birth_month      = params[:birth_month].to_s.strip
    @age_group        = params[:age_group].to_s.strip
    @life_path        = params[:life_path].to_s.strip
    @personal_year    = params[:personal_year].to_s.strip
    @brand_ambassador = params[:brand_ambassador].to_s.strip
    @big_first_filter = params[:big_first].to_s.strip
    @product_tag      = params[:product_tag].to_s.strip
    @health_tag      = params[:health_tag].to_s.strip
    @recent_purchase  = params[:recent_purchase].to_s.strip

    @membership_order = %w[黑卡 金卡 銀卡 白卡 一般會員 非會員]
    @membership_levels = ShoplineCustomer.distinct.pluck(:membership_level)
      .map { |l| l.presence || "非會員" }
      .uniq
      .sort_by { |l| @membership_order.index(l) || 99 }

    @product_tag_options = CustomerProfile::SHENGTING_PRODUCT_OPTIONS
    @health_tag_options = CustomerProfile::HEALTH_TAG_OPTIONS

    @page = params[:page].to_i
    @page = 1 if @page <= 0
    @page = MAX_PAGE if @page > MAX_PAGE

    @city_by_membership = ShoplineCustomer
      .where.not(membership_level: [nil, ""])
      .where.not(city: [nil, ""])
      .group(:membership_level, :city)
      .count
      .each_with_object(Hash.new { |h, k| h[k] = {} }) do |((level, city), cnt), h|
        h[level][city] = cnt
      end

    scope = ShoplineCustomer.includes(:customer_profile).all

    if @q.present?
      like = "%#{@q}%"
      scope = scope.where(
        "full_name ILIKE :like OR email ILIKE :like OR mobile_phone ILIKE :like OR phone ILIKE :like OR instagram_account ILIKE :like",
        like: like
      )
    end

    if @membership_level.present?
      if @membership_level == "非會員"
        scope = scope.where(membership_level: [nil, ""])
      else
        scope = scope.where(membership_level: @membership_level)
      end
    end

    scope = scope.where("current_shopping_credits >= ?", @min_credits) if @min_credits
    scope = scope.where("EXTRACT(MONTH FROM birthdate) = ?", @birth_month.to_i) if @birth_month.present?
    scope = scope.where(age_group_sql(@age_group)) if @age_group.present?
    scope = scope.where(zodiac_sql(@zodiac)) if @zodiac.present?

    if @product_tag.present?
      scope = scope.joins(:customer_profile)
                   .where("? = ANY(customer_profiles.shengting_product_tags)", @product_tag)
    end

    if @health_tag.present?
      scope = scope.joins(:customer_profile)
                  .where("? = ANY(customer_profiles.health_tags)", @health_tag)
    end

    if @life_path.present?
      lp_num = @life_path.to_i
      matching_ids = ShoplineCustomer
        .where.not(birthdate: nil)
        .pluck(:id, :birthdate)
        .select { |_, bd| life_path_number(bd) == lp_num }
        .map(&:first)
      scope = scope.where(id: matching_ids)
    end

    if @personal_year.present?
      py_num = @personal_year.to_i
      matching_ids = ShoplineCustomer
        .where.not(birthdate: nil)
        .pluck(:id, :birthdate)
        .select { |_, bd| personal_year_number(bd) == py_num }
        .map(&:first)
      scope = scope.where(id: matching_ids)
    end

    if @brand_ambassador == "1"
      scope = scope.joins(:customer_profile).where(customer_profiles: { brand_ambassador_training: true })
    end

    if @big_first_filter == "1"
      scope = scope.joins(
        "INNER JOIN (
          SELECT DISTINCT ON (email) email, total_amount AS first_amount
          FROM shopline_orders
          ORDER BY email, order_date ASC
        ) fo ON fo.email = shopline_customers.email"
      ).where("fo.first_amount >= 10000")
    end

    scope = scope
      .joins("LEFT JOIN (
        SELECT email, MAX(order_date) AS last_order_date
        FROM shopline_orders
        WHERE product_name IS NOT NULL AND product_name != ''
        GROUP BY email
      ) lo ON lo.email = shopline_customers.email")
      .select("shopline_customers.*, lo.last_order_date")

    scope = scope.where("lo.last_order_date >= ?", 3.months.ago) if @recent_purchase == "1"

    scope = scope.reorder(Arel.sql(order_sql(@sort)))

    @total = ShoplineCustomer.from(scope.except(:select, :order), :shopline_customers).count

    if @recent_purchase == "1"
      level_scope = ShoplineCustomer.all
      if @membership_level.present?
        level_scope = if @membership_level == "非會員"
          level_scope.where(membership_level: [nil, ""])
        else
          level_scope.where(membership_level: @membership_level)
        end
      end
      @recent_purchase_denominator = level_scope.count
    end

    @total_pages = (@total.to_f / PER_PAGE).ceil
    @total_pages = 1 if @total_pages <= 0
    offset = (@page - 1) * PER_PAGE
    @customers = scope.offset(offset).limit(PER_PAGE)

    emails = @customers.map(&:email).compact.uniq

    # Single query for all per-customer order data (replaces two separate queries)
    all_orders_by_email = ShoplineOrder
      .where(email: emails)
      .where.not(product_name: [nil, ""])
      .select(:email, :product_name, :quantity, :order_date)
      .group_by(&:email)

    @top_products = {}
    @inactive_info = {}
    @last_purchase_products = {}
    all_orders_by_email.each do |email, orders|
      series_counts = Hash.new { |h, k| h[k] = { qty: 0, count: 0 } }
      orders.each do |o|
        series, bottles_per_unit = parse_product(o.product_name)
        series_counts[series][:qty]   += o.quantity.to_i * bottles_per_unit
        series_counts[series][:count] += 1
      end
      @top_products[email] = series_counts.max_by { |_, v| [v[:qty], v[:count]] }&.first

      last_order = orders.max_by(&:order_date)
      if last_order&.order_date
        last_date = last_order.order_date
        last_series = orders.select { |o| o.order_date == last_date }
                             .map { |o| parse_product(o.product_name).first }
                             .uniq
        @last_purchase_products[email] = last_series

        days_ago = (Date.today - last_date.to_date).to_i
        @inactive_info[email] = { days: days_ago, last_product: last_series.first } if days_ago >= 60
      end
    end

    first_orders_by_email = ShoplineOrder
      .where(email: emails)
      .select("DISTINCT ON (email) email, order_date, total_amount")
      .order("email, order_date ASC")
      .index_by(&:email)

    @big_first_orders = {}
    first_orders_by_email.each do |email, order|
      @big_first_orders[email] = order.order_date if order.total_amount.to_f >= 10_000
    end

    @credits_expiring_count = Rails.cache.fetch("credits_expiring_count:#{Date.today}", expires_in: 12.hours) do
      ShoplineOrder
        .where.not(product_name: [nil, ""])
        .group(:email)
        .having("MAX(order_date::date) BETWEEN ? AND ?", Date.today - 358, Date.today - 355)
        .joins("JOIN shopline_customers sc ON sc.email = shopline_orders.email")
        .where("sc.current_shopping_credits > 0")
        .count.size
    end
  end

  def show
    @customer = ShoplineCustomer.find(params[:id])
    @profile  = @customer.customer_profile || @customer.build_customer_profile

    @orders_page  = [params[:orders_page].to_i, 1].max
    @orders_total = ShoplineOrder.where(email: @customer.email).count
    @orders_pages = (@orders_total.to_f / 10).ceil
    @orders       = ShoplineOrder.where(email: @customer.email)
                      .order(order_date: :desc)
                      .offset((@orders_page - 1) * 10)
                      .limit(10)

    all_orders = ShoplineOrder.where(email: @customer.email).order(order_date: :desc)
    @product_analysis = analyze_products(all_orders)

    # 各系列最後購買日
    series_last_date = Hash.new
    all_orders.each do |o|
      next if o.product_name.blank?
      matched = series_options.select { |s| o.product_name.include?(s) || (s == "益生菌" && o.product_name.include?("益生箘")) }
      matched.each do |s|
        d = o.order_date&.to_date
        series_last_date[s] = d if d && (series_last_date[s].nil? || d > series_last_date[s])
      end
    end

    purchased_series    = series_last_date.keys
    @unpurchased_series = series_options - purchased_series

    today = Date.today
    @no_repurchase_3m = series_last_date.select { |_, d| (today - d).to_i > 90  }.keys
    @no_repurchase_6m = series_last_date.select { |_, d| (today - d).to_i > 180 }.keys

    @life_path     = @customer.birthdate.present? ? life_path_number(@customer.birthdate) : nil
    @personal_year = @customer.birthdate.present? ? personal_year_number(@customer.birthdate) : nil
    @zodiac_sign   = @customer.birthdate.present? ? zodiac_sign(@customer.birthdate) : nil
  end

  def stats
    @membership_order = %w[黑卡 金卡 銀卡 白卡 一般會員 非會員]
    @customers_report_updated_at = ImportRun.where(kind: "customers_report")
                                              .order(started_at: :desc)
                                              .first&.finished_at

    customers = ShoplineCustomer.select(:membership_level, :city, :birthdate)

    @total_by_level      = Hash.new(0)
    @city_stats          = Hash.new { |h, k| h[k] = Hash.new(0) }
    @birth_month_stats   = Hash.new { |h, k| h[k] = Hash.new(0) }
    @life_path_stats     = Hash.new { |h, k| h[k] = Hash.new(0) }
    @age_group_stats     = Hash.new { |h, k| h[k] = Hash.new(0) }
    @zodiac_stats        = Hash.new { |h, k| h[k] = Hash.new(0) }
    @personal_year_stats = Hash.new { |h, k| h[k] = Hash.new(0) }

    customers.each do |c|
      lvl = c.membership_level.presence || "非會員"
      @total_by_level[lvl] += 1
      @city_stats[lvl][c.city] += 1 if c.city.present?

      next unless c.birthdate.present?

      @birth_month_stats[lvl][c.birthdate.month] += 1
      @age_group_stats[lvl][age_group(c.birthdate)] += 1
      @zodiac_stats[lvl][zodiac_sign(c.birthdate)] += 1

      lp = life_path_number(c.birthdate)
      @life_path_stats[lvl][lp] += 1 if lp

      py = personal_year_number(c.birthdate)
      @personal_year_stats[lvl][py] += 1 if py
    end

    load_new_member_stats
    load_membership_level_trend
    @membership_manual_reference = MEMBERSHIP_MANUAL_REFERENCE
  end

  def edit
    @customer = ShoplineCustomer.find(params[:id])
    @profile  = @customer.customer_profile || @customer.build_customer_profile
    @edit_section = params[:section].to_s.presence || "notes"
    @product_tag_options     = CustomerProfile::PRODUCT_TAG_OPTIONS
    @health_tag_options      = CustomerProfile::HEALTH_TAG_OPTIONS
    @shengting_product_options = CustomerProfile::SHENGTING_PRODUCT_OPTIONS
  end

  def update
    @customer = ShoplineCustomer.find(params[:id])
    @profile  = @customer.customer_profile || @customer.build_customer_profile
    @edit_section = params[:section].to_s.presence || "notes"
    @product_tag_options     = CustomerProfile::PRODUCT_TAG_OPTIONS
    @health_tag_options      = CustomerProfile::HEALTH_TAG_OPTIONS
    @shengting_product_options = CustomerProfile::SHENGTING_PRODUCT_OPTIONS

    if params[:customer_profile]
      params[:customer_profile][:health_tags]&.reject!(&:blank?)
      params[:customer_profile][:product_tags]&.reject!(&:blank?)
      params[:customer_profile][:shengting_product_tags]&.reject!(&:blank?)
    end

    if @profile.update(profile_params)
      log_customer_edit(@customer, @profile, @edit_section)
      redirect_to customer_path(@customer), notice: "已儲存"
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def export_credits_expiring
    # 最後購買在 355~358 天前（距 365 天到期還有 7~10 天）且有購物金
    window_start = Date.today - 358
    window_end   = Date.today - 355

    expiring_emails = ShoplineOrder
      .where.not(product_name: [nil, ""])
      .group(:email)
      .having("MAX(order_date::date) BETWEEN ? AND ?", window_start, window_end)
      .pluck(:email)

    customers = ShoplineCustomer
      .where(email: expiring_emails)
      .where("current_shopping_credits > 0")
      .order(current_shopping_credits: :desc)

    last_orders = ShoplineOrder
      .where(email: expiring_emails)
      .where.not(product_name: [nil, ""])
      .group(:email)
      .maximum(:order_date)

    csv_data = CSV.generate(encoding: "UTF-8") do |csv|
      csv << ["姓名", "Email", "手機", "會員等級", "購物金", "最後購買日", "距歸零天數", "IG 帳號"]
      customers.each do |c|
        last_date      = last_orders[c.email]&.to_date
        days_remaining = last_date ? 365 - (Date.today - last_date).to_i : nil
        ig_link = c.instagram_account.present? ? "https://www.instagram.com/#{c.instagram_account.delete_prefix('@')}" : nil
        csv << [
          c.full_name, c.email, c.mobile_phone, c.membership_level,
          c.current_shopping_credits.to_i,
          last_date&.strftime("%Y/%m/%d"),
          days_remaining,
          ig_link
        ]
      end
    end

    send_data "\xEF\xBB\xBF" + csv_data,
      filename: "購物金即將歸零_#{Date.today}.csv",
      type: "text/csv; charset=utf-8"
  end

  def export_inactive
    threshold_days = (params[:days] || 365).to_i
    cutoff_date = Date.today - threshold_days

    # 用 customer_purchase_summaries 判斷：已處理 mobile_phone 身份合併、只計算已付款訂單
    customers = ShoplineCustomer
      .joins(<<~SQL)
        JOIN customer_purchase_summaries cps
          ON cps.identity_key = COALESCE(NULLIF(TRIM(shopline_customers.mobile_phone), ''), LOWER(TRIM(shopline_customers.email)))
      SQL
      .where("cps.last_order_date < ?", cutoff_date)
      .where("shopline_customers.current_shopping_credits > 0")
      .select("shopline_customers.*, cps.last_order_date AS cps_last_order_date")
      .order("shopline_customers.current_shopping_credits DESC")

    respond_to do |format|
      format.csv do
        csv_data = CSV.generate(encoding: "UTF-8") do |csv|
          csv << ["Shopline連結", "姓名", "Email", "會員等級", "購物金", "最後購買日", "未購天數"]
          customers.each do |c|
            last_date = c.cps_last_order_date&.to_date
            days = last_date ? (Date.today - last_date).to_i : nil
            csv << [
              "https://admin.shoplineapp.com/admin/yardley/users/#{c.shopline_id}",
              c.full_name,
              c.email,
              c.membership_level,
              c.current_shopping_credits,
              last_date&.strftime("%Y/%m/%d"),
              days
            ]
          end
        end

        send_data "\xEF\xBB\xBF" + csv_data,
          filename: "未購#{threshold_days}天_有購物金名單_#{Date.today}.csv",
          type: "text/csv; charset=utf-8"
      end
    end
  end

  private

  # 新增會員數（依 Shopline member_registered_at，資料回溯到 2023 年底，
  # 不需要快照就能算今年 vs 去年）
  def load_new_member_stats
    today = Date.current
    this_year = today.year
    last_year = this_year - 1

    registered_at = ShoplineCustomer.where.not(member_registered_at: nil).pluck(:member_registered_at)

    @new_members_ytd_this_year = registered_at.count { |t| t.year == this_year && t <= today.end_of_day }
    @new_members_ytd_last_year = registered_at.count do |t|
      t.year == last_year && t <= Date.new(last_year, today.month, today.day).end_of_day
    end
    @new_members_last_full_year = registered_at.count { |t| t.year == last_year }

    @new_members_by_month = (1..12).map do |m|
      { month: m,
        this_year: registered_at.count { |t| t.year == this_year && t.month == m },
        last_year: registered_at.count { |t| t.year == last_year && t.month == m } }
    end
  end

  # 卡別人數趨勢：跟最新快照比較 7天前／30天前／去年同期（快照剛開始蒐集時，
  # 較舊的比較基準會是 nil，畫面上顯示「資料累積中」）
  def load_membership_level_trend
    @snapshot_levels = %w[黑卡 金卡 銀卡 白卡 一般會員 非會員]
    @latest_snapshot = MembershipLevelSnapshot.order(snapshot_date: :desc).first
    return unless @latest_snapshot

    today = @latest_snapshot.snapshot_date
    @snapshot_baselines = {
      d7:  MembershipLevelSnapshot.closest_to(today - 7),
      d30: MembershipLevelSnapshot.closest_to(today - 30),
      y1:  MembershipLevelSnapshot.closest_to(today - 365)
    }.transform_values { |snap| snap == @latest_snapshot ? nil : snap }
  end

  def log_customer_edit(customer, profile, section)
    changes = profile.previous_changes.except("updated_at", "created_at", "id", "shopline_customer_id")
    return if changes.empty?
    CustomerEditLog.create!(
      customer_id:   customer.id,
      user_id:       current_user&.id,
      customer_name: customer.full_name,
      section:       section,
      changes_json:  changes
    )
  rescue StandardError
  end

  def profile_params
    params.require(:customer_profile).permit(
      :brand_ambassador_training,
      :brand_ambassador_blacklisted,
      :follows_chloe_ig,
      :invited_to_follow_product_ig,
      :notes,
      :health_profile,
      :feedback,
      :special_attention,
      product_tags: [],
      health_tags: [],
      shengting_product_tags: []
    )
  end

  def age_group_sql(group)
    case group
    when "未滿 25" then "EXTRACT(YEAR FROM AGE(birthdate)) < 25"
    when "25–29"   then "EXTRACT(YEAR FROM AGE(birthdate)) BETWEEN 25 AND 29"
    when "30–34"   then "EXTRACT(YEAR FROM AGE(birthdate)) BETWEEN 30 AND 34"
    when "35–39"   then "EXTRACT(YEAR FROM AGE(birthdate)) BETWEEN 35 AND 39"
    when "40–44"   then "EXTRACT(YEAR FROM AGE(birthdate)) BETWEEN 40 AND 44"
    when "45 以上" then "EXTRACT(YEAR FROM AGE(birthdate)) >= 45"
    end
  end

  def zodiac_sql(sign)
    {
      "牡羊" => "(EXTRACT(MONTH FROM birthdate)=3  AND EXTRACT(DAY FROM birthdate)>=21) OR (EXTRACT(MONTH FROM birthdate)=4  AND EXTRACT(DAY FROM birthdate)<=19)",
      "金牛" => "(EXTRACT(MONTH FROM birthdate)=4  AND EXTRACT(DAY FROM birthdate)>=20) OR (EXTRACT(MONTH FROM birthdate)=5  AND EXTRACT(DAY FROM birthdate)<=20)",
      "雙子" => "(EXTRACT(MONTH FROM birthdate)=5  AND EXTRACT(DAY FROM birthdate)>=21) OR (EXTRACT(MONTH FROM birthdate)=6  AND EXTRACT(DAY FROM birthdate)<=20)",
      "巨蟹" => "(EXTRACT(MONTH FROM birthdate)=6  AND EXTRACT(DAY FROM birthdate)>=21) OR (EXTRACT(MONTH FROM birthdate)=7  AND EXTRACT(DAY FROM birthdate)<=22)",
      "獅子" => "(EXTRACT(MONTH FROM birthdate)=7  AND EXTRACT(DAY FROM birthdate)>=23) OR (EXTRACT(MONTH FROM birthdate)=8  AND EXTRACT(DAY FROM birthdate)<=22)",
      "處女" => "(EXTRACT(MONTH FROM birthdate)=8  AND EXTRACT(DAY FROM birthdate)>=23) OR (EXTRACT(MONTH FROM birthdate)=9  AND EXTRACT(DAY FROM birthdate)<=22)",
      "天秤" => "(EXTRACT(MONTH FROM birthdate)=9  AND EXTRACT(DAY FROM birthdate)>=23) OR (EXTRACT(MONTH FROM birthdate)=10 AND EXTRACT(DAY FROM birthdate)<=22)",
      "天蠍" => "(EXTRACT(MONTH FROM birthdate)=10 AND EXTRACT(DAY FROM birthdate)>=23) OR (EXTRACT(MONTH FROM birthdate)=11 AND EXTRACT(DAY FROM birthdate)<=21)",
      "射手" => "(EXTRACT(MONTH FROM birthdate)=11 AND EXTRACT(DAY FROM birthdate)>=22) OR (EXTRACT(MONTH FROM birthdate)=12 AND EXTRACT(DAY FROM birthdate)<=21)",
      "摩羯" => "(EXTRACT(MONTH FROM birthdate)=12 AND EXTRACT(DAY FROM birthdate)>=22) OR (EXTRACT(MONTH FROM birthdate)=1  AND EXTRACT(DAY FROM birthdate)<=19)",
      "水瓶" => "(EXTRACT(MONTH FROM birthdate)=1  AND EXTRACT(DAY FROM birthdate)>=20) OR (EXTRACT(MONTH FROM birthdate)=2  AND EXTRACT(DAY FROM birthdate)<=18)",
      "雙魚" => "(EXTRACT(MONTH FROM birthdate)=2  AND EXTRACT(DAY FROM birthdate)>=19) OR (EXTRACT(MONTH FROM birthdate)=3  AND EXTRACT(DAY FROM birthdate)<=20)"
    }[sign]
  end

  def age_group(birthdate)
    age = ((Date.today - birthdate.to_date) / 365.25).floor
    case age
    when 0..24  then "未滿 25"
    when 25..29 then "25–29"
    when 30..34 then "30–34"
    when 35..39 then "35–39"
    when 40..44 then "40–44"
    else             "45 以上"
    end
  end

  def zodiac_sign(date)
    m, d = date.month, date.day
    case
    when (m == 3  && d >= 21) || (m == 4  && d <= 19) then "牡羊"
    when (m == 4  && d >= 20) || (m == 5  && d <= 20) then "金牛"
    when (m == 5  && d >= 21) || (m == 6  && d <= 20) then "雙子"
    when (m == 6  && d >= 21) || (m == 7  && d <= 22) then "巨蟹"
    when (m == 7  && d >= 23) || (m == 8  && d <= 22) then "獅子"
    when (m == 8  && d >= 23) || (m == 9  && d <= 22) then "處女"
    when (m == 9  && d >= 23) || (m == 10 && d <= 22) then "天秤"
    when (m == 10 && d >= 23) || (m == 11 && d <= 21) then "天蠍"
    when (m == 11 && d >= 22) || (m == 12 && d <= 21) then "射手"
    when (m == 12 && d >= 22) || (m == 1  && d <= 19) then "摩羯"
    when (m == 1  && d >= 20) || (m == 2  && d <= 18) then "水瓶"
    else "雙魚"
    end
  end

  def life_path_number(date)
    sum = date.strftime("%Y%m%d").chars.map(&:to_i).sum
    loop do
      break if sum <= 9
      sum = sum.to_s.chars.map(&:to_i).sum
    end
    sum
  end

  def personal_year_number(birthdate)
    year_sum = Date.today.year.digits.sum
    month_sum = birthdate.month.digits.sum
    day_sum = birthdate.day.digits.sum
    sum = year_sum + month_sum + day_sum
    loop do
      break if sum <= 9
      sum = sum.to_s.chars.map(&:to_i).sum
    end
    sum
  end

  def analyze_products(orders)
    today = Date.today
    series_grouped = Hash.new { |h, k| h[k] = [] }

    orders.where.not(product_name: [nil, ""]).each do |order|
      expand_product(order.product_name).each do |series, bottles_per_unit|
        series_grouped[series] << {
          order: order,
          bottles_per_unit: bottles_per_unit,
          bottles_total: (order.quantity.to_i * bottles_per_unit)
        }
      end
    end

    series_grouped.map do |series_name, items|
      items_sorted = items.sort_by { |i| i[:order].order_date || Date.new(0) }
      dates = items_sorted.map { |i| i[:order].order_date&.to_date }.compact.uniq.sort

      total_qty_bottles     = items.sum { |i| i[:bottles_total] }
      total_amount          = items.sum { |i| i[:order].total_amount.to_f }
      order_count           = items.map { |i| i[:order].order_number }.uniq.size
      last_purchase_bottles = items_sorted.last&.fetch(:bottles_total) || 0

      avg_cycle_days = if dates.size >= 2
        intervals = dates.each_cons(2).map { |a, b| (b - a).to_i }.reject { |i| i <= 0 }
        intervals.any? ? (intervals.sum.to_f / intervals.size).round : nil
      end

      avg_bottles_per_purchase = order_count > 0 ? (total_qty_bottles.to_f / order_count).round(1) : nil

      days_per_bottle = if avg_cycle_days && avg_bottles_per_purchase && avg_bottles_per_purchase > 0
        (avg_cycle_days.to_f / avg_bottles_per_purchase).round(1)
      end

      days_since_last = dates.last ? (today - dates.last).to_i : nil

      estimated_stock = if days_per_bottle && days_since_last && last_purchase_bottles > 0
        (last_purchase_bottles - (days_since_last.to_f / days_per_bottle)).round(1)
      end

      estimated_empty_date = if days_per_bottle && dates.last && last_purchase_bottles > 0
        dates.last + (last_purchase_bottles * days_per_bottle).round
      end

      overdue_days = if estimated_empty_date && today > estimated_empty_date
        (today - estimated_empty_date).to_i
      end

      {
        product_name:             series_name,
        order_count:              order_count,
        total_qty_bottles:        total_qty_bottles,
        total_amount:             total_amount,
        first_date:               dates.first,
        last_date:                dates.last,
        last_purchase_bottles:    last_purchase_bottles,
        avg_bottles_per_purchase: avg_bottles_per_purchase,
        avg_cycle_days:           avg_cycle_days,
        days_per_bottle:          days_per_bottle,
        days_since_last:          days_since_last,
        estimated_stock:          estimated_stock,
        estimated_empty_date:     estimated_empty_date,
        overdue_days:             overdue_days,
        dates:                    dates
      }
    end.sort_by { |p| [-p[:total_qty_bottles], -p[:order_count], p[:avg_cycle_days] || Float::INFINITY] }
  end

  def series_options
    @series_options ||= CrmProduct.series_labels_for_filter
  end

  def expand_product(name)
    matches = series_options.filter_map do |s|
      next unless name.include?(s)
      m = name.match(/#{Regexp.escape(s)}(\d+)/)
      [s, m ? m[1].to_i : 1]
    end
    return matches if matches.any?
    name =~ /^(.+?)(\d+)$/ ? [[$1.strip, $2.to_i]] : [[name, 1]]
  end

  def parse_product(name)
    series_options.each do |s|
      next unless name.include?(s)
      m = name.match(/#{Regexp.escape(s)}(\d+)/)
      return [s, m ? m[1].to_i : 1]
    end
    name =~ /^(.+?)(\d+)$/ ? [$1.strip, $2.to_i] : [name, 1]
  end

  def to_number(v)
    s = v.to_s.strip
    return nil if s.blank?
    s = s.gsub(/[,\uFF0C]/, "")
    Float(s)
  rescue ArgumentError
    nil
  end

  def order_sql(sort)
    case sort
    when "amount_desc"   then "total_amount DESC NULLS LAST, id DESC"
    when "amount_asc"    then "total_amount ASC NULLS LAST, id DESC"
    when "orders_desc"   then "order_count DESC NULLS LAST, id DESC"
    when "orders_asc"    then "order_count ASC NULLS LAST, id DESC"
    when "credits_desc"  then "current_shopping_credits DESC NULLS LAST, id DESC"
    when "credits_asc"   then "current_shopping_credits ASC NULLS LAST, id DESC"
    when "inactive_desc" then "lo.last_order_date ASC NULLS LAST, id DESC"
    when "inactive_asc"  then "lo.last_order_date DESC NULLS LAST, id DESC"
    when "last_purchase_desc" then "lo.last_order_date DESC NULLS LAST, id DESC"
    when "last_purchase_asc"  then "lo.last_order_date ASC NULLS LAST, id DESC"
    when "newest"        then "created_at DESC, id DESC"
    else "total_amount DESC NULLS LAST, id DESC"
    end
  end
end