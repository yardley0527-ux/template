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
    @graph_api_configured = ENV["IG_GRAPH_ACCESS_TOKEN"].present? && ig_follower_snapshots_table_ready?
  end

  # 網頁上的「立即更新粉絲數」按鈕：用 Graph API 抓 13 個品牌帳號（不含 chloechao0527，
  # 那是個人帳號，Graph API 不支援，繼續用 script/update_ig_followers.sh 在本機更新）。
  def update_now
    unless ig_follower_snapshots_table_ready?
      return redirect_to ig_followers_path, alert: "資料表還沒建立好（migration 可能還沒跑），請稍後再試一次。"
    end

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

  # 同一帳號兩邊都有資料時，比較「哪邊最後一筆日期比較新」決定用誰的——不能無條件
  # 讓 DB 贏（之前的寫法），不然 ig_follower_snapshots 只在資料表第一次被讀到是空的
  # 時候，從 JSON 整批 backfill 一次，之後就凍結住：沒設定 IG_GRAPH_ACCESS_TOKEN
  # （「立即更新」按鈕不會動）的帳號，本機 script 對 JSON 的更新會被那次性的舊快照
  # 永久蓋掉，看起來像是「怎麼推都沒生效」。這樣改之後，DB 只在真的比 JSON 新（例如
  # 之後有設定 Graph API 且按了「立即更新」）時才會贏，否則用本機 script 剛更新的
  # JSON——回傳的形狀跟原本的 ig_followers_data.json 一模一樣，view 端的 JS 不用改。
  #
  # 用 ig_follower_snapshots_table_ready? 保護：如果正式站的 migration 還沒跑（新
  # 資料表還不存在），就先只用 JSON 檔案顯示舊資料，不要整頁 500。
  def merged_data
    json_data = File.exist?(DATA_PATH) ? JSON.parse(File.read(DATA_PATH)) : {}
    return json_data unless ig_follower_snapshots_table_ready?

    IgFollowerSnapshot.backfill_if_empty!

    db_data = IgFollowerSnapshot.order(:snapshot_date).group_by(&:account).transform_values do |rows|
      rows.map { |r| { "date" => r.snapshot_date.to_s, "followers" => r.followers } }
    end

    json_data.merge(db_data) do |_account, json_entries, db_entries|
      json_last = json_entries.last&.dig("date")
      db_last = db_entries.last&.dig("date")
      (db_last && (json_last.nil? || db_last > json_last)) ? db_entries : json_entries
    end
  end

  def ig_follower_snapshots_table_ready?
    ActiveRecord::Base.connection.data_source_exists?("ig_follower_snapshots")
  end
end
