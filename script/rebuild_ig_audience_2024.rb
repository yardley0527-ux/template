#!/usr/bin/env ruby
# script/rebuild_ig_audience_2024.rb
#
# 重新產生 data/ig_audience_data.json
# 只計算「2024年以後有訂單」的買家
#
# 用法：
#   ruby script/rebuild_ig_audience_2024.rb
#
# 需要：gem install pg（已在 Gemfile 裡）

require "json"
require "set"
require "pg"
require "time"
require "uri"

# ── 路徑設定 ───────────────────────────────────────────────────────────
SHENGTING_DIR = "/Users/serenachang/Downloads/connections 2/followers_and_following"
CHLOE_DIR     = "/Users/serenachang/Downloads/connections/followers_and_following"
OUTPUT_PATH   = File.expand_path("../data/ig_audience_data.json", __dir__)

DB_URL = "postgresql://st_crm_ver2_user:s31QzpFS3lVQvol1QSxPuIIVVJs1EcpE@dpg-d665gd9r0fns73chtcv0-a.singapore-postgres.render.com/st_crm_ver2"

# ── Helper: 讀取 IG export 粉絲名單 ────────────────────────────────────
def load_ig_followers(dir)
  set = Set.new
  files = Dir.glob(File.join(dir, "followers_*.json")).sort
  files.each do |f|
    data = JSON.parse(File.read(f))
    data.each do |entry|
      entry.fetch("string_list_data", []).each do |item|
        username = item["value"]&.strip&.downcase
        set.add(username) if username && !username.empty?
      end
    end
  end
  puts "  #{dir.split('/').last(2).join('/')}: #{set.size} 人"
  set
end

# ── Helper: normalize IG handle（同 ShoplineCustomer.normalize_ig）───────
def normalize_ig(raw)
  return nil if raw.nil? || raw.strip.empty?
  raw = raw.strip.downcase
  raw = raw.sub(/\Ahttps?:\/\/(www\.)?instagram\.com\//, "")
  raw = raw.split(/[?\/]/).first.to_s.strip
  raw.start_with?("@") ? raw[1..] : raw
end

# ── Step 1：讀取 IG 粉絲 ────────────────────────────────────────────────
puts "\n[1/4] 載入 Instagram 粉絲資料..."
shengting_set = load_ig_followers(SHENGTING_DIR)
chloe_set     = load_ig_followers(CHLOE_DIR)

overlap_count = (shengting_set & chloe_set).size
overlap_pct   = shengting_set.size > 0 ? (overlap_count.to_f / shengting_set.size * 100).round(1) : 0
puts "  shengting ∩ chloe：#{overlap_count} 人（占 shengting #{overlap_pct}%）"

# ── Step 2：連線 Production DB ─────────────────────────────────────────
puts "\n[2/4] 連線 Production DB..."
uri    = URI.parse(DB_URL)
conn   = PG.connect(
  host:     uri.host,
  port:     uri.port || 5432,
  dbname:   uri.path.sub(/^\//, ""),
  user:     uri.user,
  password: uri.password,
  sslmode:  "require"
)
puts "  ✅ 連線成功"

# ── Step 3：查詢 2024+ 買家（有 IG 帳號） ──────────────────────────────
puts "\n[3/4] 查詢 2024 年後有訂單的買家（有填 IG 帳號）..."

sql = <<~SQL
  SELECT
    c.email,
    c.full_name,
    c.instagram_account,
    c.phone,
    COUNT(o.id)               AS order_count,
    COALESCE(SUM(o.total_amount), 0) AS total_amount
  FROM shopline_customers c
  JOIN shopline_orders o
    ON o.email = c.email
   AND o.payment_status = '已付款'
   AND o.order_date >= '2024-01-01'
  WHERE c.instagram_account IS NOT NULL
    AND c.instagram_account != ''
  GROUP BY c.email, c.full_name, c.instagram_account, c.phone
  ORDER BY total_amount DESC
SQL

buyers = conn.exec(sql).to_a
puts "  → #{buyers.size} 位買家"

# ── Step 4：分群 ────────────────────────────────────────────────────────
puts "\n[4/4] 分群比對..."

segments = {
  "target"     => [],  # 追蹤 shengting + 未追蹤 chloe + 有買
  "both"       => [],  # 兩邊都追蹤 + 有買
  "chloe_only" => [],  # 只追蹤 chloe + 有買
  "neither"    => [],  # 兩邊都沒追蹤 + 有買
}

buyers.each do |row|
  ig = normalize_ig(row["instagram_account"])
  next if ig.nil? || ig.empty?

  in_shengting = shengting_set.include?(ig)
  in_chloe     = chloe_set.include?(ig)

  entry = {
    "ig"     => ig,
    "name"   => row["full_name"],
    "email"  => row["email"],
    "phone"  => row["phone"],
    "orders" => row["order_count"].to_i,
    "amount" => row["total_amount"].to_f.round(0).to_i
  }

  key = if in_shengting && !in_chloe
    "target"
  elsif in_shengting && in_chloe
    "both"
  elsif !in_shengting && in_chloe
    "chloe_only"
  else
    "neither"
  end

  segments[key] << entry
end

total_buyers = buyers.size

# ── 輸出 JSON ─────────────────────────────────────────────────────────
result = {
  "last_updated"       => Time.now.strftime("%Y-%m-%d %H:%M"),
  "shengting_followers"=> shengting_set.size,
  "chloe_followers"    => chloe_set.size,
  "overlap_count"      => overlap_count,
  "overlap_pct"        => overlap_pct,
  "total_buyers_with_ig"=> total_buyers,
  "note"               => "僅計算 2024-01-01 以後有訂單的買家（shengting_official 2024 年才開始經營）",
  "highlights"         => [],
  "segments"           => segments.transform_values { |arr|
    { "count" => arr.size, "buyers" => arr }
  }
}

File.write(OUTPUT_PATH, JSON.pretty_generate(result))
conn.close

puts "\n" + "=" * 50
puts "✅ 完成！結果已寫入：#{OUTPUT_PATH}"
puts ""
puts "分群結果（2024年後買家）："
segments.each do |key, arr|
  pct = total_buyers > 0 ? (arr.size.to_f / total_buyers * 100).round(1) : 0
  puts "  #{key.ljust(12)}: #{arr.size} 人（#{pct}%）"
end
puts "  合計：#{total_buyers} 人"
puts "=" * 50
