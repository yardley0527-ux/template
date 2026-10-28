# 行銷機會頁的 AI 建議（手動觸發、背景產生），見 CreateMarketingSuggestionsAndDrafts migration。
class MarketingAiSuggestion < ApplicationRecord
  STATUSES = %w[pending running success invalid_response failed].freeze
  IN_PROGRESS = %w[pending running].freeze
  # 產生中的建議超過這個時間還沒結束，視為卡住，可以重新產生
  STALE_AFTER = 15.minutes

  has_many :marketing_campaign_drafts, dependent: :nullify

  validates :status, inclusion: { in: STATUSES }

  def self.in_progress
    where(status: IN_PROGRESS).where("created_at > ?", STALE_AFTER.ago)
  end

  REQUEST_LOCK_KEY = 2_026_102_901 # pg advisory lock：同時按兩次只會建立一筆

  # 重複點擊防護：已經有產生中的就回傳那一筆，不重複呼叫 AI。
  # 背景工作在 commit 之後才排入，避免工作先跑、卻還讀不到這筆。
  def self.request!(user:, now: Time.current)
    created = false
    suggestion = transaction do
      connection.execute("SELECT pg_advisory_xact_lock(#{REQUEST_LOCK_KEY})")
      in_progress.first || begin
        snapshot = Marketing::SnapshotBuilder.new(now: now).call
        created = true
        create!(status: "pending", input_snapshot: snapshot, rule_version: snapshot["rule_version"],
                data_as_of: snapshot.dig("data_as_of", "manychat_last_sync"), requested_by_user_id: user&.id)
      end
    end
    MarketingAiSuggestionJob.perform_later(suggestion.id) if created
    suggestion
  end

  def in_progress? = IN_PROGRESS.include?(status) && created_at > STALE_AFTER.ago

  def segment(id) = Array(input_snapshot["segments"]).find { |s| s["id"] == id }

  def metric(id) = Array(input_snapshot["metrics"]).find { |m| m["id"] == id } || segment(id)

  def product_label(key) = Array(input_snapshot["products"]).find { |p| p["key"] == key }&.dig("label") || key

  def promotion(id) = Array(input_snapshot["promotions"]).find { |p| p["id"] == id }
end
