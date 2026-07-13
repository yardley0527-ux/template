# lib/tasks/ig_audience_analysis.rake
#
# IG 受眾重疊分析
# 找出：追蹤 shengting_official、有購買紀錄、但未追蹤 chloechao0527 的客戶
#
# 用法：
#   rake ig:audience_analysis                  # 完整分析（抓兩個帳號，~$193 Apify 費用）
#   rake ig:audience_analysis[shengting_only]  # 只抓 shengting（~$26），先看 DB 交集有多少人
#
# 前置條件：
#   export APIFY_TOKEN=your_token_here
#
# 輸出：
#   tmp/ig_audience_analysis_YYYYMMDD_HHMM.csv

require "net/http"
require "json"
require "csv"
require "set"

namespace :ig do
  desc "IG 受眾重疊分析：找出追蹤品牌帳號但未追蹤 Chloe 的購買客戶"
  task :audience_analysis, [:mode] => :environment do |_, args|
    mode  = args[:mode].presence || "full"
    token = ENV["APIFY_TOKEN"].presence or abort("❌ 請先設定 APIFY_TOKEN 環境變數")

    helper = IgAudienceApifyClient.new(token)

    puts "=" * 60
    puts "🔍 IG 受眾分析 — #{Time.current.strftime('%Y-%m-%d %H:%M')}"
    puts "   模式：#{mode == 'full' ? '完整分析（兩帳號）' : 'shengting_only（省 ~$167）'}"
    puts "=" * 60

    # ── Step 1：抓 shengting_official 粉絲 ──────────────────────────
    puts "\n[1/4] 抓取 @shengting_official 粉絲清單（~22k，費用約 $26）..."
    shengting_followers = helper.fetch_followers("shengting_official", 25_000)
    puts "      → 取得 #{shengting_followers.size} 人"

    shengting_set    = Set.new(shengting_followers.map { |f| f["username"]&.downcase }.compact)
    shengting_by_ig  = shengting_followers.index_by { |f| f["username"]&.downcase }

    # ── Step 2：選擇性抓 chloechao0527 粉絲 ────────────────────────
    chloe_set = Set.new

    if mode == "full"
      puts "\n[2/4] 抓取 @chloechao0527 粉絲清單（~139k，費用約 $167）..."
      chloe_followers = helper.fetch_followers("chloechao0527", 150_000)
      puts "      → 取得 #{chloe_followers.size} 人"
      chloe_set = Set.new(chloe_followers.map { |f| f["username"]&.downcase }.compact)
    else
      puts "\n[2/4] ⏭  shengting_only 模式，跳過 chloe 粉絲抓取"
    end

    # ── Step 3：查 Shopline 購買客戶（有填 IG 帳號） ────────────────
    puts "\n[3/4] 比對 Shopline 購買客戶..."
    buyers_with_ig = ShoplineCustomer
      .where.not(instagram_account: [nil, ""])
      .where("order_count > 0")
      .select(:email, :full_name, :instagram_account, :order_count, :total_amount, :phone)
    puts "      → 有填 IG 帳號且有購買：#{buyers_with_ig.count} 人"

    # ── Step 4：交叉分析 + 輸出 CSV ─────────────────────────────────
    puts "\n[4/4] 交叉分析中..."

    timestamp = Time.current.strftime("%Y%m%d_%H%M")
    out_path  = Rails.root.join("tmp", "ig_audience_analysis_#{timestamp}.csv")

    db_ig_set = Set.new(
      buyers_with_ig.map { |c| ShoplineCustomer.normalize_ig(c.instagram_account) }.compact
    )

    # 計數器
    target_count     = 0  # 🎯 追蹤品牌＋有購買＋未追蹤Chloe
    both_follow      = 0  # ✅ 兩邊都追蹤＋有購買
    brand_no_data    = 0  # 📦 追蹤品牌＋有購買（chloe未確認）

    CSV.open(out_path, "w", encoding: "UTF-8") do |csv|
      csv << [
        "IG帳號",
        "IG顯示名稱",
        "追蹤shengting_official",
        "追蹤chloechao0527",
        "有Shopline購買紀錄",
        "客戶姓名",
        "客戶Email",
        "客戶電話",
        "訂單數",
        "總消費金額",
        "分類標籤"
      ]

      # ── 區塊 A：Shopline 買過的客戶，有無追蹤品牌 ────────────────
      buyers_with_ig.each do |customer|
        ig_handle = ShoplineCustomer.normalize_ig(customer.instagram_account)
        next if ig_handle.blank?

        in_shengting = shengting_set.include?(ig_handle)
        in_chloe     = mode == "full" ? chloe_set.include?(ig_handle) : nil
        ig_data      = shengting_by_ig[ig_handle]

        label = if in_shengting && in_chloe == false
          target_count += 1
          "🎯 目標：追蹤品牌＋有購買＋未追蹤Chloe"
        elsif in_shengting && in_chloe
          both_follow += 1
          "✅ 兩邊都追蹤＋有購買"
        elsif in_shengting
          brand_no_data += 1
          "📦 追蹤品牌＋有購買（Chloe未確認）"
        else
          "⚪ 有購買但未追蹤品牌"
        end

        csv << [
          ig_handle,
          ig_data&.dig("fullName") || ig_data&.dig("full_name"),
          in_shengting ? "是" : "否",
          in_chloe.nil? ? "未抓取" : (in_chloe ? "是" : "否"),
          "是",
          customer.full_name,
          customer.email,
          customer.phone,
          customer.order_count,
          customer.total_amount&.to_s("F"),
          label
        ]
      end

      # ── 區塊 B：shengting 粉絲，無 Shopline 購買紀錄 ─────────────
      shengting_followers.each do |f|
        ig_handle = f["username"]&.downcase
        next if ig_handle.blank? || db_ig_set.include?(ig_handle)

        in_chloe = mode == "full" ? chloe_set.include?(ig_handle) : nil

        label = if in_chloe == false
          "🔍 追蹤品牌＋未追蹤Chloe（無購買）"
        elsif in_chloe
          "➡️ 兩邊都追蹤（無購買）"
        else
          "⬜ 追蹤品牌（Chloe未確認，無購買）"
        end

        csv << [
          ig_handle,
          f["fullName"] || f["full_name"],
          "是",
          in_chloe.nil? ? "未抓取" : (in_chloe ? "是" : "否"),
          "否",
          "", "", "", "", "",
          label
        ]
      end
    end

    # ── 摘要報告 ─────────────────────────────────────────────────────
    shengting_only_size = mode == "full" ? (shengting_set - chloe_set).size : "（未計算）"

    puts "\n" + "=" * 60
    puts "📊 分析摘要"
    puts "=" * 60
    puts "  @shengting_official 粉絲：         #{shengting_set.size} 人"
    puts "  @chloechao0527 粉絲：              #{mode == 'full' ? "#{chloe_set.size} 人" : '（未抓取）'}"
    puts "  只追蹤品牌、未追蹤Chloe：          #{shengting_only_size}#{mode == 'full' ? ' 人' : ''}"
    puts "  有購買且有填IG帳號的客戶：          #{buyers_with_ig.count} 人"
    puts ""
    puts "  🎯 目標受眾（追蹤品牌＋購買＋未追蹤Chloe）：#{target_count} 人"
    puts "  ✅ 兩邊都追蹤且有購買：                      #{both_follow} 人"
    if mode == "shengting_only"
      puts "  📦 追蹤品牌＋購買（Chloe未確認）：          #{brand_no_data} 人"
    end
    puts ""
    puts "✅ 報表已輸出：#{out_path}"
    puts "=" * 60
  end
end

# ─────────────────────────────────────────────────────────────────────
# IgAudienceApifyClient — 僅供此 rake task 使用，不進 autoload 路徑
# ─────────────────────────────────────────────────────────────────────
class IgAudienceApifyClient
  ACTOR_ID   = "datadoping~instagram-followers-scraper"
  BASE_URL   = "https://api.apify.com/v2"
  POLL_SLEEP = 10    # 秒，輪詢間隔
  TIMEOUT    = 3600  # 秒，最長等待 1 小時

  def initialize(token)
    @token = token
  end

  # 抓取指定帳號的粉絲清單，回傳 Array of Hash
  def fetch_followers(username, max_count)
    run_id, dataset_id = start_run(username, max_count)
    puts "      → Apify Run ID: #{run_id}（正在等待完成...）"
    wait_for_completion(run_id)
    items = fetch_all_items(dataset_id)
    items
  end

  private

  def start_run(username, max_count)
    uri  = URI("#{BASE_URL}/acts/#{ACTOR_ID}/runs?token=#{@token}")
    body = { usernames: [username], max_count: max_count }.to_json
    resp = post_json(uri, body)

    unless resp.dig("data", "id")
      raise "❌ 啟動 Apify run 失敗：#{resp.inspect}"
    end

    [ resp.dig("data", "id"), resp.dig("data", "defaultDatasetId") ]
  end

  def wait_for_completion(run_id)
    deadline = Time.current + TIMEOUT
    loop do
      raise "⏰ 超過 #{TIMEOUT / 60} 分鐘仍未完成，請至 Apify Dashboard 確認" if Time.current > deadline

      status = fetch_run_status(run_id)
      print "        status=#{status}...\r"
      $stdout.flush

      case status
      when "SUCCEEDED"
        puts "        ✅ 完成                    "
        break
      when "FAILED", "ABORTED", "TIMED-OUT"
        raise "❌ Apify run 異常結束（#{status}）：run_id=#{run_id}"
      end

      sleep POLL_SLEEP
    end
  end

  def fetch_run_status(run_id)
    uri = URI("#{BASE_URL}/actor-runs/#{run_id}?token=#{@token}")
    get_json(uri).dig("data", "status")
  end

  # 分頁抓取 dataset 所有資料
  def fetch_all_items(dataset_id)
    all_items = []
    offset    = 0
    limit     = 1000

    loop do
      uri = URI("#{BASE_URL}/datasets/#{dataset_id}/items")
      uri.query = URI.encode_www_form(
        token:  @token,
        offset: offset,
        limit:  limit,
        clean:  true
      )
      batch = get_json(uri)
      break if batch.empty?

      all_items.concat(batch)
      break if batch.size < limit

      offset += limit
      print "        已下載 #{all_items.size} 筆...\r"
      $stdout.flush
    end

    all_items
  end

  def post_json(uri, body)
    http = build_http(uri)
    req  = Net::HTTP::Post.new(uri)
    req["Content-Type"] = "application/json"
    req.body = body
    JSON.parse(http.request(req).body)
  end

  def get_json(uri)
    http = build_http(uri)
    JSON.parse(http.request(Net::HTTP::Get.new(uri)).body)
  end

  def build_http(uri)
    http           = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl   = true
    http.read_timeout = 30
    http
  end
end
