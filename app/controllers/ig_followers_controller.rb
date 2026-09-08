class IgFollowersController < ApplicationController
  DATA_PATH = Rails.root.join("data", "ig_followers_data.json")

  NAMES = {
    "shengting_official"      => "苼莛 官方",
    "shengting.collagen"      => "膠原蛋白",
    "shengting.vitaminbczinc" => "全能",
    "shengting.bodyfit"       => "清纖粉",
    "shengting.slim"          => "薑黃",
    "shengting.hercare"       => "私密處",
    "shengting.vitaminDbone"  => "維生素D",
    "shengting.metabolic"     => "代謝錠",
    "shengting.fishoil"       => "魚油",
    "shengting.probiotic"     => "益生菌",
    "shengting.glow"          => "穀胱甘肽",
    "shengting.light"         => "抗老",
    "shengting.eyeprotect"    => "蝦紅素",
    "chloechao0527"           => "Chloe IG",
  }.freeze

  def index
    @data = merged_data
    @last_updated = @data.values.flatten.map { |e| e["date"] }.max
    @names = NAMES
    @graph_api_configured = ENV["IG_GRAPH_ACCESS_TOKEN"].present?
  end

  # 網頁上的「立即更新粉絲數」按鈕：用 Graph API 抓 13 個品牌帳號（不含 chloechao0527，
  # 那是個人帳號，Graph API 不支援，繼續用 script/update_ig_followers.sh 在本機更新）。
  def update_now
    results = IgGraphApiFollowerFetcher.call
    results.each do |r|
      IgFollowerSnapshot.upsert_today!(account: r.username, followers: r.followers) if r.ok?
    end

    ok_count = results.count(&:ok?)
    failed = results.reject(&:ok?)

    if failed.empty?
      redirect_to ig_followers_path, notice: "已更新 #{ok_count} 個帳號的粉絲數。"
    else
      failed_list = failed.map { |r| "#{NAMES[r.username] || r.username}（#{r.error}）" }.join("、")
      redirect_to ig_followers_path, alert: "成功 #{ok_count} 個，失敗：#{failed_list}"
    end
  end

  private

  # DB（Graph API 更新的 13 個品牌帳號）優先，JSON 檔案（本機 script 更新的
  # chloechao0527 + 尚未 backfill 的舊資料）補齊其餘——回傳的形狀跟原本的
  # ig_followers_data.json 一模一樣，view 端的 JS 完全不用改。
  def merged_data
    json_data = File.exist?(DATA_PATH) ? JSON.parse(File.read(DATA_PATH)) : {}

    db_data = IgFollowerSnapshot.order(:snapshot_date).group_by(&:account).transform_values do |rows|
      rows.map { |r| { "date" => r.snapshot_date.to_s, "followers" => r.followers } }
    end

    json_data.merge(db_data)
  end
end
