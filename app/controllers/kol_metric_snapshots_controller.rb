# path: app/controllers/kol_metric_snapshots_controller.rb
# frozen_string_literal: true

class KolMetricSnapshotsController < ApplicationController
  def create
    @candidate = KolCandidate.find(params[:kol_candidate_id])
    snapshot = @candidate.kol_metric_snapshots.new(snapshot_params)

    if snapshot.save
      redirect_to @candidate, notice: "已新增 #{snapshot.platform} 數據快照"
    else
      redirect_to @candidate, alert: snapshot.errors.full_messages.join("、")
    end
  end

  def destroy
    @candidate = KolCandidate.find(params[:kol_candidate_id])
    @candidate.kol_metric_snapshots.find(params[:id]).destroy
    redirect_to @candidate, notice: "已刪除該筆數據快照"
  end

  private

  def snapshot_params
    params.require(:kol_metric_snapshot).permit(
      :platform, :followers_count, :following_count, :posts_count,
      :engagement_rate, :avg_views, :avg_likes, :source, :fetched_at
    )
  end
end
