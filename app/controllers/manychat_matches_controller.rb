# ManyChat 訂閱者身分比對：列出候選、人工確認／排除／解除。每個操作都記 ManychatMatchLog，
# 確認過的關聯同步時不會被覆蓋。只看得到候選顧客的姓名與卡別等比對所需資訊。
class ManychatMatchesController < ApplicationController
  def index
    @status = params[:status].presence_in(ManychatSubscriber::MATCH_STATUSES.keys) || "candidate"
    @counts = ManychatSubscriber.group(:match_status).count
    @subscribers = ManychatSubscriber.where(match_status: @status).order(updated_at: :desc).limit(200).to_a
    ids = @subscribers.flat_map { |s| s.candidate_customer_ids + [s.shopline_customer_id, s.legacy_shopline_customer_id] }.compact.uniq
    @customers = ShoplineCustomer.where(id: ids).index_by(&:id)
    @logs = ManychatMatchLog.where(manychat_subscriber_id: @subscribers.map(&:id)).order(created_at: :desc)
                            .includes(:user).group_by(&:manychat_subscriber_id)
  end

  def confirm = decide { |sub| sub.confirm!(params.require(:customer_id), user: current_user, note: params[:note]) }

  def reject = decide { |sub| sub.reject!(params.require(:customer_id), user: current_user, note: params[:note]) }

  def unlink = decide { |sub| sub.unlink!(user: current_user, note: params[:note]) }

  private

  def decide
    sub = ManychatSubscriber.find(params[:id])
    yield sub
    redirect_back fallback_location: manychat_matches_path, notice: "已更新 @#{sub.ig_username} 的身分比對"
  rescue ArgumentError, ActionController::ParameterMissing => e
    redirect_back fallback_location: manychat_matches_path, alert: e.message
  end
end
