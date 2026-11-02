# IG 收件匣：還沒回的私訊（Meta 對話 API 同步），老闆在這裡直接回；附 AI 分類、敏感標記與每日總結。
class IgInboxController < ApplicationController
  STALE_AFTER = 5.minutes
  TABS = { "waiting" => "待回覆", "ignored" => "不用回", "replied" => "最近已回" }.freeze

  def index
    @configured = IgInbox::Client.accounts.any?
    @last_sync = SyncRun.where(source: "ig_inbox").order(:id).last
    IgInboxSyncJob.perform_later if @configured && stale?

    @tab = params[:tab].presence_in(TABS.keys) || "waiting"
    scope = IgConversation.includes(:ig_messages)
    @conversations =
      case @tab
      when "waiting" then scope.waiting.order(sensitive: :desc, last_customer_message_at: :asc)
      when "ignored" then scope.where(status: "ignored").order(last_message_at: :desc)
      else scope.where(awaiting_reply: false).order(last_message_at: :desc)
      end
    @conversations = @conversations.where(category: params[:category]) if params[:category].present?
    @conversations = @conversations.limit(100)

    @counts = { "waiting" => IgConversation.waiting.count, "ignored" => IgConversation.where(status: "ignored").count }
    @category_counts = IgConversation.waiting.group(:category).count.sort_by { |_, n| -n }
    @digest = IgInboxDigest.where(status: %w[done pending failed]).order(day: :desc).first
  end

  def reply
    conversation = IgConversation.find(params[:id])
    IgInbox::Reply.call(conversation, params[:text], user: current_user)
    redirect_back fallback_location: ig_inbox_index_path, notice: "已回覆 #{conversation.display_name}"
  rescue IgInbox::Reply::Error => e
    redirect_back fallback_location: ig_inbox_index_path, alert: "回覆 #{conversation.display_name} 失敗：#{e.message}"
  end

  def update
    conversation = IgConversation.find(params[:id])
    conversation.update!(status: params[:status]) if params[:status].in?(IgConversation::STATUSES.keys)
    redirect_back fallback_location: ig_inbox_index_path
  end

  def sync
    IgInboxSyncJob.perform_later
    redirect_to ig_inbox_index_path, notice: "已開始同步，約半分鐘後重新整理頁面"
  end

  def regenerate_digest
    day = Date.parse(params[:day])
    IgInboxDigest.find_or_create_by!(day: day).update!(status: "pending", error_message: nil)
    IgInboxDigestJob.perform_later(day.iso8601)
    redirect_to ig_inbox_index_path, notice: "已開始重新整理 #{day.strftime('%-m/%-d')} 的總結，約 1–2 分鐘後重新整理頁面"
  end

  private

  def stale?
    @last_sync.nil? || (@last_sync.status != "running" && @last_sync.started_at < STALE_AFTER.ago)
  end
end
