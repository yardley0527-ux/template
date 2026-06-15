require 'csv'
require 'set'

class ManychatAudienceController < ApplicationController
  def index
    @chloe_snapshots    = ManychatSnapshot.where(account_type: 'chloe').order(created_at: :desc)
    @official_snapshots = ManychatSnapshot.where(account_type: 'official').order(created_at: :desc)

    chloe_id    = params[:chloe_snapshot_id]&.to_i    || @chloe_snapshots.first&.id
    official_id = params[:official_snapshot_id]&.to_i || @official_snapshots.first&.id

    @selected_chloe    = chloe_id    ? ManychatSnapshot.find_by(id: chloe_id)    : nil
    @selected_official = official_id ? ManychatSnapshot.find_by(id: official_id) : nil

    if @selected_chloe && @selected_official
      chloe_set    = Set.new(ManychatIguid.where(manychat_snapshot_id: @selected_chloe.id).pluck(:iguid))
      official_set = Set.new(ManychatIguid.where(manychat_snapshot_id: @selected_official.id).pluck(:iguid))

      @overlap_count        = (official_set & chloe_set).size
      @only_official_count  = (official_set - chloe_set).size
      @only_chloe_count     = (chloe_set - official_set).size
    end
  end

  def upload
    account_type = params[:account_type]
    file         = params[:csv_file]

    unless %w[chloe official].include?(account_type)
      return redirect_to manychat_audience_path, alert: "不明的帳號類型"
    end
    return redirect_to manychat_audience_path, alert: "請選擇 CSV 檔案" unless file

    iguids = []
    CSV.foreach(file.path, headers: true) do |row|
      ig = row['iguid']&.strip
      iguids << ig if ig.present?
    end

    return redirect_to manychat_audience_path, alert: "CSV 格式不符或空白" if iguids.empty?

    snapshot = ManychatSnapshot.create!(account_type: account_type, iguid_count: iguids.size)
    ManychatIguid.insert_all(iguids.map { |ig| { manychat_snapshot_id: snapshot.id, iguid: ig } })

    redirect_to manychat_audience_path, notice: "已匯入 #{number_with_delimiter(iguids.size)} 筆（#{snapshot.account_label}）"
  end

  def export
    chloe_snap    = ManychatSnapshot.find_by(id: params[:chloe_snapshot_id])
    official_snap = ManychatSnapshot.find_by(id: params[:official_snapshot_id])

    return redirect_to manychat_audience_path, alert: "請先選擇快照" unless chloe_snap && official_snap

    chloe_set    = Set.new(ManychatIguid.where(manychat_snapshot_id: chloe_snap.id).pluck(:iguid))
    official_ids = ManychatIguid.where(manychat_snapshot_id: official_snap.id).pluck(:iguid)
    target       = official_ids.reject { |ig| chloe_set.include?(ig) }

    csv = CSV.generate { |c| c << ['iguid']; target.each { |ig| c << [ig] } }
    send_data csv,
              filename:    "target_audience_#{Date.today}.csv",
              type:        'text/csv',
              disposition: 'attachment'
  end

  private

  def number_with_delimiter(n)
    n.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
  end
end
