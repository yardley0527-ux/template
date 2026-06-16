class IgAudienceController < ApplicationController
  DATA_PATH = Rails.root.join("data", "ig_audience_data.json")

  SEGMENT_META = {
    "target"     => { label: "🎯 追蹤品牌＋有買＋未追蹤 Chloe",  color: "#f0ad4e" },
    "both"       => { label: "✅ 兩邊都追蹤＋有買（核心受眾）",    color: "#5cb85c" },
    "chloe_only" => { label: "📌 追蹤 Chloe＋有買＋未追蹤品牌",   color: "#337ab7" },
    "neither"    => { label: "⚪ 有買但兩邊都未追蹤",              color: "#888"    }
  }.freeze

  def index
    @data = load_data
    return unless @data

    @last_updated        = @data["last_updated"]
    @shengting_followers = @data["shengting_followers"]
    @chloe_followers     = @data["chloe_followers"]
    @overlap_count       = @data["overlap_count"]
    @overlap_pct         = @data["overlap_pct"]
    @total_buyers        = @data["total_buyers_with_ig"]

    seg = @data["segments"]
    @target     = seg["target"]
    @both       = seg["both"]
    @chloe_only = seg["chloe_only"]
    @neither    = seg["neither"]

    @active_tab = params[:tab] || "target"
  end

  def detail
    @data = load_data
    return redirect_to ig_audience_path, alert: "尚無資料" unless @data

    @tab  = params[:tab].presence || "both"
    return redirect_to ig_audience_path unless SEGMENT_META.key?(@tab)

    @meta    = SEGMENT_META[@tab]
    @buyers  = @data.dig("segments", @tab, "buyers") || []
    @count      = @buyers.size
    @per_page   = 50
    @page       = [params[:page].to_i, 1].max
    @total_pages = (@count.to_f / @per_page).ceil
    @page       = [@page, @total_pages].min if @total_pages > 0
    @paged_buyers = @buyers.slice((@page - 1) * @per_page, @per_page) || []
    @emails     = @buyers.map { |b| b["email"] }.compact.uniq

    if @emails.any?
      orders = ShoplineOrder
        .where(email: @emails, payment_status: "已付款")
        .where.not(product_name: [nil, ""])

      # ── 商品排行 ─────────────────────────────────────────────
      @top_products = orders
        .group(:product_name)
        .select(
          :product_name,
          "SUM(quantity)    AS total_qty",
          "SUM(total_amount) AS total_revenue",
          "COUNT(DISTINCT email) AS buyer_count"
        )
        .order("total_revenue DESC")
        .limit(20)

      # ── 月份趨勢 ─────────────────────────────────────────────
      @monthly = orders
        .where.not(order_date: nil)
        .group("TO_CHAR(order_date, 'YYYY-MM')")
        .select(
          "TO_CHAR(order_date, 'YYYY-MM') AS ym",
          "COUNT(*) AS order_count",
          "SUM(total_amount) AS revenue"
        )
        .order("ym")

      # ── 星期幾 ───────────────────────────────────────────────
      @by_weekday = orders
        .where.not(order_date: nil)
        .group("EXTRACT(DOW FROM order_date)::int")
        .select(
          "EXTRACT(DOW FROM order_date)::int AS dow",
          "COUNT(*) AS order_count",
          "SUM(total_amount) AS revenue"
        )
        .order("dow")

      # ── 時段 ─────────────────────────────────────────────────
      @by_hour = orders
        .where.not(order_date: nil)
        .group("EXTRACT(HOUR FROM order_date)::int")
        .select(
          "EXTRACT(HOUR FROM order_date)::int AS hour",
          "COUNT(*) AS order_count",
          "SUM(total_amount) AS revenue"
        )
        .order("hour")
    else
      @top_products = []
      @monthly = @by_weekday = @by_hour = []
    end
  end

  def export
    @data = load_data
    return redirect_to ig_audience_path, alert: "尚無資料" unless @data

    tab    = params[:tab] || "target"
    buyers = @data.dig("segments", tab, "buyers") || []
    label  = SEGMENT_META.dig(tab, :label) || tab

    csv_data = CSV.generate(encoding: "UTF-8") do |csv|
      csv << %w[IG帳號 客戶姓名 Email 電話 訂單數 總消費金額 分類]
      buyers.each do |b|
        csv << [b["ig"], b["name"], b["email"], b["phone"],
                b["orders"], b["amount"], label]
      end
    end

    send_data "\xEF\xBB\xBF" + csv_data,
              filename:    "ig_audience_#{tab}_#{Date.today}.csv",
              type:        "text/csv; charset=utf-8",
              disposition: "attachment"
  end

  private

  def load_data
    File.exist?(DATA_PATH) ? JSON.parse(File.read(DATA_PATH)) : nil
  end
end
