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

    @active_tab = params[:tab] || "chloe_only"

    # ── 當前分群的商品 & 時間快覽 ─────────────────────────────────
    active_buyers = @data.dig("segments", @active_tab, "buyers") || []
    @active_count  = active_buyers.size
    @active_emails = active_buyers.map { |b| b["email"] }.compact.uniq

    if @active_emails.any?
      orders = ShoplineOrder
        .where(email: @active_emails, payment_status: "已付款")
        .where.not(product_name: [nil, ""])

      @tab_top_products = orders
        .group(:product_name)
        .select(:product_name,
                "SUM(quantity) AS total_qty",
                "SUM(total_amount) AS total_revenue",
                "COUNT(DISTINCT email) AS buyer_count")
        .order("SUM(total_amount) DESC NULLS LAST")
        .limit(5)

      @tab_by_weekday = orders
        .where.not(order_date: nil)
        .group("EXTRACT(DOW FROM order_date)::int")
        .select("EXTRACT(DOW FROM order_date)::int AS dow",
                "COUNT(*) AS order_count",
                "SUM(total_amount) AS revenue")
        .order("dow")

      @tab_by_hour = orders
        .where.not(order_date: nil)
        .group("EXTRACT(HOUR FROM order_date)::int")
        .select("EXTRACT(HOUR FROM order_date)::int AS hour",
                "COUNT(*) AS order_count",
                "SUM(total_amount) AS revenue")
        .order("hour")

      @tab_total_revenue = orders.sum(:total_amount)
    end

    # 分頁（買家名單）
    @per_page    = 50
    @page        = [params[:page].to_i, 1].max
    @total_pages = (active_buyers.size.to_f / @per_page).ceil
    @page        = [@page, [@total_pages, 1].max].min
    @paged_buyers = active_buyers.slice((@page - 1) * @per_page, @per_page) || []
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

      # ── 商品排行（所有訂單）───────────────────────────────────
      @top_products = orders
        .group(:product_name)
        .select(
          :product_name,
          "SUM(quantity)     AS total_qty",
          "SUM(total_amount) AS total_revenue",
          "COUNT(DISTINCT email) AS buyer_count"
        )
        .order("SUM(total_amount) DESC NULLS LAST")
        .limit(5)

      # ── 首次購買分析 ─────────────────────────────────────────
      # 每位客戶最早的那筆訂單
      first_orders_sql = <<~SQL
        SELECT DISTINCT ON (email) email, product_name, order_date, total_amount
        FROM shopline_orders
        WHERE email = ANY(ARRAY[#{@emails.map { |e| "'#{e.gsub("'", "''")}'" }.join(",")}])
          AND payment_status = '已付款'
          AND product_name IS NOT NULL AND product_name != ''
          AND order_date IS NOT NULL
        ORDER BY email, order_date ASC
      SQL
      first_orders = ActiveRecord::Base.connection.execute(first_orders_sql).to_a

      # 首購商品排行
      @first_top_products = first_orders
        .group_by { |r| r["product_name"] }
        .map { |name, rows|
          { product_name: name,
            buyer_count:  rows.size,
            revenue:      rows.sum { |r| r["total_amount"].to_f } }
        }
        .sort_by { |p| -p[:revenue] }
        .first(5)

      # 首購月份
      @first_by_month = first_orders
        .group_by { |r| Time.parse(r["order_date"]).strftime("%Y-%m") rescue nil }
        .reject { |k, _| k.nil? }
        .map { |ym, rows|
          { ym: ym, order_count: rows.size, revenue: rows.sum { |r| r["total_amount"].to_f } }
        }
        .sort_by { |r| r[:ym] }

      # 首購星期幾
      @first_by_weekday = first_orders
        .group_by { |r| Time.parse(r["order_date"]).wday rescue nil }
        .reject { |k, _| k.nil? }
        .map { |dow, rows|
          { dow: dow, order_count: rows.size, revenue: rows.sum { |r| r["total_amount"].to_f } }
        }
        .sort_by { |r| r[:dow] }

      # 首購時段
      @first_by_hour = first_orders
        .group_by { |r| Time.parse(r["order_date"]).hour rescue nil }
        .reject { |k, _| k.nil? }
        .map { |hour, rows|
          { hour: hour, order_count: rows.size, revenue: rows.sum { |r| r["total_amount"].to_f } }
        }
        .sort_by { |r| r[:hour] }

      # ── 購買軌跡（完整序列） ──────────────────────────────────
      traj_sql = <<~SQL
        SELECT email, order_date, product_name, total_amount,
               ROW_NUMBER() OVER (PARTITION BY email ORDER BY order_date) AS purchase_no
        FROM shopline_orders
        WHERE email = ANY(ARRAY[#{@emails.map { |e| "'#{e.gsub("'", "''")}'" }.join(",")}])
          AND payment_status = '已付款'
          AND product_name IS NOT NULL AND product_name != ''
          AND order_date IS NOT NULL
        ORDER BY email, order_date
      SQL
      traj_rows = ActiveRecord::Base.connection.execute(traj_sql).to_a
      traj_by_person = traj_rows.group_by { |r| r["email"] }

      @repurchase_count = traj_by_person.count { |_, os| os.size >= 2 }
      @repurchase_rate  = traj_by_person.size > 0 ?
        (@repurchase_count.to_f / traj_by_person.size * 100).round(1) : 0

      gaps = []
      traj_by_person.each do |_, os|
        dates = os.map { |r| Date.parse(r["order_date"].to_s[0..9]) rescue nil }.compact
        dates.each_cons(2) { |a, b| gaps << (b - a).to_i }
      end
      @median_gap_days = gaps.any? ? gaps.sort[gaps.size / 2] : nil

      @avg_spend_per_customer = traj_by_person.size > 0 ?
        (traj_rows.sum { |r| r["total_amount"].to_f } / traj_by_person.size).round(0) : 0

      @seq_first  = rank_seq(traj_rows.select { |r| r["purchase_no"].to_i == 1 })
      @seq_second = rank_seq(traj_rows.select { |r| r["purchase_no"].to_i == 2 })
      @seq_third  = rank_seq(traj_rows.select { |r| r["purchase_no"].to_i == 3 })

      buyer_map = @buyers.index_by { |b| b["email"] }
      @customer_sequences = traj_by_person.map do |email, os|
        buyer = buyer_map[email]
        { name:     buyer&.dig("name") || email,
          email:    email,
          count:    os.size,
          total:    os.sum { |r| r["total_amount"].to_f },
          products: os.map { |r| r["product_name"] } }
      end.sort_by { |c| -c[:total] }

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

      # ── 星期幾（所有訂單） ────────────────────────────────────
      @by_weekday = orders
        .where.not(order_date: nil)
        .group("EXTRACT(DOW FROM order_date)::int")
        .select(
          "EXTRACT(DOW FROM order_date)::int AS dow",
          "COUNT(*) AS order_count",
          "SUM(total_amount) AS revenue"
        )
        .order("dow")

      # ── 時段（所有訂單） ─────────────────────────────────────
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
      @top_products       = []
      @first_top_products = []
      @first_by_weekday   = []
      @first_by_hour      = []
      @first_by_month     = []
      @monthly = @by_weekday = @by_hour = []
      @repurchase_count = @repurchase_rate = @median_gap_days = @avg_spend_per_customer = nil
      @seq_first = @seq_second = @seq_third = []
      @customer_sequences = []
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

  def rank_seq(rows, limit = 5)
    rows.group_by { |r| r["product_name"] }
        .map { |name, rs| { name: name, count: rs.size } }
        .sort_by { |p| -p[:count] }
        .first(limit)
  end
end
