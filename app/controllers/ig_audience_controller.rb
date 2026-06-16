class IgAudienceController < ApplicationController
  DATA_PATH = Rails.root.join("data", "ig_audience_data.json")

  def index
    @data = File.exist?(DATA_PATH) ? JSON.parse(File.read(DATA_PATH)) : nil
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

  def export
    @data = File.exist?(DATA_PATH) ? JSON.parse(File.read(DATA_PATH)) : nil
    return redirect_to ig_audience_path, alert: "尚無資料" unless @data

    tab = params[:tab] || "target"
    buyers = @data.dig("segments", tab, "buyers") || []

    label_map = {
      "target"     => "追蹤品牌＋有買＋未追蹤Chloe",
      "both"       => "兩邊都追蹤＋有買",
      "chloe_only" => "追蹤Chloe＋有買＋未追蹤品牌",
      "neither"    => "有買但兩邊都未追蹤"
    }

    csv_data = CSV.generate(encoding: "UTF-8") do |csv|
      csv << %w[IG帳號 客戶姓名 Email 電話 訂單數 總消費金額 分類]
      buyers.each do |b|
        csv << [b["ig"], b["name"], b["email"], b["phone"],
                b["orders"], b["amount"], label_map[tab]]
      end
    end

    filename = "ig_audience_#{tab}_#{Date.today}.csv"
    send_data "\xEF\xBB\xBF" + csv_data,
              filename:    filename,
              type:        "text/csv; charset=utf-8",
              disposition: "attachment"
  end
end
