# script/fetch_line_broadcasts.rb
# 用法: bin/rails runner script/fetch_line_broadcasts.rb
#
# 設定要抓取的 Google Sheet（每個 entry 一份 CSV）
SHEETS = [
  { year: 2024, url: "https://docs.google.com/spreadsheets/d/1K5P3ngno4J9e9MtztkJKkBmJmzKNM4-PmcW5zv2JNYk/export?format=csv&gid=2124865452" },
  { year: 2025, url: "https://docs.google.com/spreadsheets/d/1E5S2Ev0sizqrkR-FkN20jZ-vVd8k8pg7qtfR9OZ9PnM/export?format=csv&gid=1968093715" },
].freeze

require 'csv'
require 'open-uri'
require 'json'

def parse_pct(s)  = s.to_s.gsub('%', '').strip.to_f
def parse_money(s) = s.to_s.gsub(/[^\d.]/, '').to_f

all_broadcasts = []

SHEETS.each do |sheet|
  puts "Fetching #{sheet[:year]}..."
  begin
    content = URI.open(sheet[:url], read_timeout: 30).read
    csv = CSV.parse(content, headers: true)
    rows = csv.reject { |row| row['主題'].blank? || row['推播時間'].blank? }
    rows.each do |row|
      all_broadcasts << {
        year:                  sheet[:year],
        topic:                 row['主題'].to_s.strip,
        push_time:             row['推播時間'].to_s.strip,
        message_success:       row['訊息成功數'].to_i,
        message_success_rate:  parse_pct(row['訊息成功率']),
        read:                  row['已讀'].to_i,
        read_rate:             parse_pct(row['已讀率']),
        clicks:                row['點擊數'].to_i,
        ctr:                   parse_pct(row['CTR']),
        response_12h:          row['12 小時回應數'].to_i,
        response_12h_rate:     parse_pct(row['12 小時回應率']),
        response_24h:          row['24 小時回應數'].to_i,
        response_24h_rate:     parse_pct(row['24 小時回應率']),
        response_48h:          row['48 小時回應數'].to_i,
        response_48h_rate:     parse_pct(row['48 小時回應率']),
        unsubscribe:           row['退訂封鎖數'].to_i,
        unsubscribe_rate:      parse_pct(row['退訂封鎖率']),
        orders:                row['訂單數'].to_i,
        revenue:               parse_money(row['營業額']),
      }
    end
    puts "  -> #{rows.size} rows"
  rescue => e
    puts "  ERROR: #{e.message}"
  end
end

output = {
  product:      '苼莛國際生技',
  channel:      'LINE 官方帳號',
  last_updated: Date.today.to_s,
  broadcasts:   all_broadcasts.sort_by { |b| b[:push_time] }
}

path = Rails.root.join('data', 'line_broadcast_data.json')
File.write(path, JSON.pretty_generate(output))
puts "\nDone! #{all_broadcasts.size} total rows -> #{path}"
