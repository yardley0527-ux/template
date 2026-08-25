class DailyOrdersController < ApplicationController
  include HighValueOrderScoping

  TIERS = %w[黑卡 金卡 銀卡 白卡 一般會員].freeze
  TOGGLEABLE_FIELDS = %w[follows_chloe_ig invited_to_follow_product_ig health_inquiry_declined recipe_message_sent].freeze
  PURCHASE_SUMMARY_FIELDS = %w[line_bound].freeze

  # 這頁是給每日出貨備貨用的，一次撈整個區間所有訂單、逐筆拉客戶資料，不分頁。
  # 區間拉太長（例如整年）撈出的客戶數一多，Rails 對 customer_profile 的 includes
  # 會產生上千個 bind 參數的 IN 查詢，曾經因此把 Render 記憶體吃爆、整個服務 502。
  MAX_RANGE_DAYS = 31

  # IG 搜尋不受日期區間限制（讓使用者不用先猜對日期），但要限制筆數，
  # 不然熱門字串（例如單一個字）會撈出全站訂單，重蹈 502 覆轍。
  IG_SEARCH_LIMIT = 200

  ORDER_TOTAL_SQL = <<~SQL.squish.freeze
    CASE
      WHEN MAX(NULLIF(o.total_amount, 0)) IS NOT NULL THEN MAX(NULLIF(o.total_amount, 0))
      ELSE SUM(COALESCE(o.checkout_amount, 0))
    END
  SQL

  OrderRow = Struct.new(
    :order_number, :customer_name, :ig_account, :email, :order_total, :order_date,
    :is_new_customer, :membership_level, :products_list, :health_profile, :health_tags,
    :follows_chloe_ig, :invited_to_follow_product_ig, :shopline_customer_id,
    :line_bound, :total_quantity, :health_inquiry_declined, :recipe_message_sent,
    :has_repurchased,
    keyword_init: true
  )

  def index
    @start_date = parse_date(params[:start_date]) || parse_date(params[:date]) || Time.zone.yesterday
    @end_date   = parse_date(params[:end_date]) || @start_date
    @end_date   = @start_date if @end_date < @start_date
    @ig_search  = params[:ig_search].presence
    if !@ig_search && clamp_end_date!
      flash.now[:alert] = "查詢區間最多 #{MAX_RANGE_DAYS} 天，已自動縮短為 #{@start_date.strftime('%Y/%m/%d')}～#{@end_date.strftime('%Y/%m/%d')}"
    end
    @tab = %w[new old].include?(params[:tab]) ? params[:tab] : "new"
    @series_options = CrmProduct.series_labels_for_filter
    @series_filter  = params[:series_filter].presence
    @first_purchase_only = params[:first_purchase_only] == "1"
    @groups = build_groups(@start_date, @end_date)
    @new_count = @groups.first.last.size
    @old_count = @groups.drop(1).sum { |_, rows| rows.size }

    # IG 搜尋時結果可能全部落在另一個 tab（例如搜到的人今天不是新客），
    # 自動切去有資料的 tab，不然會看起來像搜不到東西
    if @ig_search.present?
      @tab = "old" if @tab == "new" && @new_count.zero? && @old_count.positive?
      @tab = "new" if @tab == "old" && @old_count.zero? && @new_count.positive?
    end

    new_rows = @groups.first.last
    @line_bound_count = new_rows.count(&:line_bound)

    old_rows = @groups.drop(1).flat_map { |_, rows| rows }
    all_order_nums = @groups.flat_map { |_, rows| rows.map(&:order_number) }
    @gift_records = OrderGiftRecord.where(order_number: all_order_nums).index_by(&:order_number)

    # 舊客總攬：各追蹤事項各自完成 / 應完成筆數
    # 傳首購產品訊息只要訂單裡有首購商品就要處理；社群部維護訊息、CRM維護已讀、CRM維護未讀、關心訊息
    # 再加一個條件：這個人之後沒有再回購過（回購過代表已經不是需要「新客關懷」的階段了）
    first_purchase_applicable = old_rows.select { |r| (@products_by_order[r.order_number] || []).any? { |p| p[:prior_date].nil? } }
    care_applicable = care_applicable_rows(old_rows)
    @first_purchase_total = first_purchase_applicable.size
    @first_purchase_done  = first_purchase_applicable.count { |r| @gift_records[r.order_number]&.first_purchase_message_sent? }
    @care_applicable_total  = care_applicable.size
    @community_message_done = care_applicable.count { |r| @gift_records[r.order_number]&.community_maintenance_message_sent? }
    @health_card_done       = care_applicable.count { |r| @gift_records[r.order_number]&.health_card_sent? }
    @care_applicable_rows   = care_applicable
  end

  def toggle_customer_flag
    # social/crm 角色在每日訂單頁分別只能勾「社群部維護訊息」／「CRM維護已讀/CRM維護未讀」，這裡的欄位都不是，直接擋掉
    return head :forbidden if current_user.role&.key == "social"
    return head :forbidden if current_user.role&.key == "crm" && params[:page] == "daily_orders"

    field = params[:field].to_s
    return head :bad_request unless (TOGGLEABLE_FIELDS + PURCHASE_SUMMARY_FIELDS).include?(field)

    customer = ShoplineCustomer.find(params[:customer_id])
    value    = ActiveModel::Type::Boolean.new.cast(params[:value])

    if PURCHASE_SUMMARY_FIELDS.include?(field)
      summary = CustomerPurchaseSummary.find_by(email: customer.email)
      return head :not_found unless summary
      summary.update!(field => value)
    else
      profile = customer.customer_profile || customer.build_customer_profile
      profile.update!(field => value)
    end

    head :ok
  end

  def update_customer_type
    value = params[:value].to_s.presence
    return head :bad_request if value.present? && !CustomerProfile::CUSTOMER_TYPE_OPTIONS.include?(value)

    customer = ShoplineCustomer.find(params[:customer_id])
    profile  = customer.customer_profile || customer.build_customer_profile
    profile.update!(customer_type: value)

    head :ok
  end

  def export
    @start_date = parse_date(params[:start_date]) || parse_date(params[:date]) || Time.zone.yesterday
    @end_date   = parse_date(params[:end_date]) || @start_date
    @end_date   = @start_date if @end_date < @start_date
    @ig_search  = params[:ig_search].presence
    clamp_end_date! unless @ig_search
    @series_filter = params[:series_filter].presence
    @first_purchase_only = params[:first_purchase_only] == "1"
    groups = build_groups(@start_date, @end_date)

    csv_data = CSV.generate(encoding: "UTF-8") do |csv|
      csv << ["分類", "訂單號碼", "姓名", "IG", "消費金額", "購買商品", "健康狀況", "健康標籤", "是否追蹤 Chloe IG", "是否已私訊邀請追蹤產品IG", "綁定 LINE", "已傳送吃法訊息"]
      groups.each do |label, rows|
        rows.each do |row|
          csv << [
            label,
            row.order_number,
            row.customer_name,
            row.ig_account,
            row.order_total.to_i,
            row.products_list.to_s.split('、').join("\n"),
            row.health_profile.presence,
            row.health_tags.join("、"),
            row.follows_chloe_ig ? "是" : "否",
            row.invited_to_follow_product_ig ? "是" : "否",
            row.line_bound ? "是" : "否",
            row.recipe_message_sent ? "是" : "否"
          ]
        end
      end
    end

    filename = @start_date == @end_date ? "每日訂單報表_#{@start_date}.csv" : "訂單報表_#{@start_date}_#{@end_date}.csv"
    send_data "\xEF\xBB\xBF" + csv_data,
      filename: filename,
      type: "text/csv; charset=utf-8"
  end

  private

  # 舊客總攬追蹤事項（社群部維護訊息／CRM維護已讀／CRM維護未讀）共用的適用名單：
  # 訂單裡有首購商品、且首購商品後來沒有全部回購過
  def care_applicable_rows(old_rows)
    first_purchase_applicable = old_rows.select { |r| (@products_by_order[r.order_number] || []).any? { |p| p[:prior_date].nil? } }
    first_purchase_applicable.reject(&:has_repurchased)
  end

  def parse_date(value)
    Date.parse(value) if value.present?
  rescue ArgumentError
    nil
  end

  # 回傳是否有被縮短；@end_date 會被就地改成上限內的日期
  def clamp_end_date!
    max_end = @start_date + (MAX_RANGE_DAYS - 1).days
    return false if @end_date <= max_end

    @end_date = max_end
    true
  end

  def build_groups(start_date, end_date)
    range_start = start_date.beginning_of_day
    range_end   = end_date.end_of_day

    raw_orders = ShoplineOrder.from("shopline_orders o")
      .joins("LEFT JOIN shopline_customers sc ON sc.email = o.email")
      .select(
        "o.order_number AS order_num",
        "MAX(o.customer_name) AS cust_name",
        "MAX(COALESCE(sc.instagram_account, o.instagram_account)) AS ig_account",
        "MAX(COALESCE(sc.email, o.email)) AS email_val",
        "MAX(COALESCE(sc.membership_level, o.membership_level)) AS membership_level_col",
        "MAX(o.order_date) AS ord_date",
        "#{ORDER_TOTAL_SQL} AS order_total",
        "STRING_AGG(DISTINCT o.product_name || ' ×' || o.quantity::text, '、' ORDER BY o.product_name || ' ×' || o.quantity::text) AS products_list",
        "ARRAY_AGG(DISTINCT o.product_name) AS product_names_arr",
        "SUM(o.quantity) AS total_quantity"
      )
      .where("o.payment_status = '已付款'")

    if @ig_search.present?
      needle = "%#{@ig_search.strip.delete_prefix('@')}%"
      matching_order_numbers = ShoplineOrder.from("shopline_orders o")
        .joins("LEFT JOIN shopline_customers sc ON sc.email = o.email")
        .where("o.payment_status = '已付款'")
        .where("COALESCE(sc.instagram_account, o.instagram_account) ILIKE ?", needle)
        .group("o.order_number")
        .order(Arel.sql("MAX(o.order_date) DESC"))
        .limit(IG_SEARCH_LIMIT)
        .pluck(Arel.sql("o.order_number"))
      raw_orders = raw_orders.where("o.order_number IN (?)", matching_order_numbers.presence || [nil])
    else
      raw_orders = raw_orders.where("o.order_date >= ? AND o.order_date <= ?", range_start, range_end)
    end

    if @series_filter.present?
      raw_orders = raw_orders.where(
        "o.order_number IN (SELECT DISTINCT order_number FROM shopline_orders WHERE product_name LIKE ?)",
        "%#{@series_filter}%"
      )
    end

    raw_orders = raw_orders
      .group("o.order_number")
      .order(Arel.sql("MAX(o.order_date) ASC"))
      .to_a

    emails = raw_orders.map(&:email_val).compact.uniq

    prior_emails = ShoplineOrder.where(email: emails).where("order_date < ?", range_start).distinct.pluck(:email).to_set

    # 「傳首購產品訊息」勾選框只要訂單內有任一產品是該系列首購就顯示，不限金額；
    # 全部訂單（新客+舊客）都要算，因為新客/舊客的社群部維護訊息／CRM維護已讀/CRM維護未讀／關心訊息
    # 現在都要看「首購的那個產品」後來有沒有回購，不只是舊客才需要這份資料
    @products_by_order = build_products_by_order(raw_orders)

    customers_by_email = ShoplineCustomer.where(email: emails).includes(:customer_profile).index_by(&:email)
    summaries_by_email = CustomerPurchaseSummary.where(email: emails).index_by(&:email)

    rows = raw_orders.map do |o|
      customer = customers_by_email[o.email_val]
      profile  = customer&.customer_profile
      summary  = summaries_by_email[o.email_val]
      # 社群部維護訊息／CRM維護已讀/CRM維護未讀／關心訊息看「這張訂單裡的首購產品」後來有沒有回購，
      # 不是看這個人有沒有買過其他任何東西——同一張訂單裡如果薑黃首購但蝦紅素也首購，
      # 只有薑黃回購了、蝦紅素還沒，還是要繼續關懷蝦紅素，所以要「全部首購商品都回購了」才算
      order_products = @products_by_order[o.order_num] || []
      first_purchase_products = order_products.select { |p| p[:prior_date].nil? }
      all_first_purchases_repurchased = first_purchase_products.present? && first_purchase_products.all? { |p| p[:repurchased_later] }

      OrderRow.new(
        order_number: o.order_num,
        customer_name: o.cust_name,
        ig_account: o.ig_account,
        email: o.email_val,
        order_total: o.order_total,
        order_date: o.ord_date,
        is_new_customer: o.email_val.blank? || !prior_emails.include?(o.email_val),
        membership_level: o.membership_level_col,
        products_list: o.products_list,
        health_profile: profile&.health_profile,
        health_tags: profile&.health_tags || [],
        follows_chloe_ig: profile&.follows_chloe_ig || false,
        invited_to_follow_product_ig: profile&.invited_to_follow_product_ig || false,
        shopline_customer_id: customer&.id,
        line_bound: summary&.line_bound || false,
        total_quantity: o.total_quantity.to_i,
        health_inquiry_declined: profile&.health_inquiry_declined || false,
        recipe_message_sent: profile&.recipe_message_sent || false,
        has_repurchased: all_first_purchases_repurchased
      )
    end

    if @ig_search.present?
      needle = @ig_search.strip.downcase.delete_prefix("@")
      rows = rows.select { |r| r.ig_account.present? && r.ig_account.downcase.delete_prefix("@").include?(needle) }
    end

    rows = rows.sort_by { |r| -r.order_total.to_f }

    new_rows = rows.select(&:is_new_customer)
    old_rows = rows.reject(&:is_new_customer)

    if @first_purchase_only
      old_rows = old_rows.select { |r| (@products_by_order[r.order_number] || []).any? { |p| p[:prior_date].nil? } }
    end

    groups = [["新客", new_rows]]
    TIERS.each do |tier|
      tier_rows = old_rows.select { |r| r.membership_level == tier }.sort_by { |r| -r.order_total.to_f }
      groups << [tier, tier_rows]
    end
    other = old_rows.reject { |r| TIERS.include?(r.membership_level) }.sort_by { |r| -r.order_total.to_f }
    groups << ["未分級", other] if other.any?

    groups
  end

end
