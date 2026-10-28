# ManyChat 訂閱者對應表，見 CreateManychatSubscribers / AddIdentityMatchingToManychatSubscribers migration 說明。
class ManychatSubscriber < ApplicationRecord
  belongs_to :shopline_customer, optional: true
  has_many :manychat_interactions, dependent: :delete_all
  has_many :manychat_match_logs, dependent: :delete_all

  # account_key 用該 IG 帳號名稱（如 shengting.slim）；不設白名單，新開的產品帳號直接能接。
  ACCOUNT_KEY_FORMAT = /\A[a-z0-9._]{1,30}\z/
  IG_FORMAT = /\A[a-z0-9._]{2,30}\z/
  # 顧客資料裡常見的「沒有 IG」寫法，不能拿來比對
  PLACEHOLDER_IGS = %w[none no na nil null ig instagram noig no_ig 0 00 000 .. ...].freeze

  MATCH_STATUSES = {
    "verified"  => { label: "已確認身分", badge: "success" },
    "candidate" => { label: "候選比對・待確認", badge: "warning" },
    "unmatched" => { label: "未比對", badge: "secondary" }
  }.freeze

  validates :account_key, format: { with: ACCOUNT_KEY_FORMAT }
  validates :subscriber_id, presence: true, uniqueness: { scope: :account_key }
  validates :match_status, inclusion: { in: MATCH_STATUSES.keys }

  before_save :normalize_ig_username
  before_save :refresh_candidates, if: -> { new_record? || will_save_change_to_ig_username? }

  scope :verified, -> { where(match_status: "verified") }

  def self.valid_ig?(ig)
    ig.present? && ig.match?(IG_FORMAT) && !PLACEHOLDER_IGS.include?(ig)
  end

  # IG 完全相同的顧客（客人檔，或訂單上填的 IG）。多人符合時全部列為候選，不替人挑選。
  def self.candidate_ids_for_ig(ig)
    return [] unless valid_ig?(ig)

    normalized = "LOWER(TRIM(LEADING '@' FROM TRIM(instagram_account)))"
    (ShoplineCustomer.where("#{normalized} = ?", ig).order(:id).pluck(:id) +
      ShoplineOrder.where("#{normalized} = ?", ig).where.not(shopline_customer_id: nil)
                   .distinct.pluck(:shopline_customer_id)).uniq.sort
  end

  # 同步時對所有未經人工確認的人重算候選（顧客資料會隨匯入更新）。
  def self.refresh_unverified_candidates!
    where.not(match_status: "verified").find_each do |sub|
      sub.send(:refresh_candidates)
      sub.save! if sub.changed?
    end
  end

  def verified? = match_status == "verified"

  def match_status_label = MATCH_STATUSES.dig(match_status, :label)

  def candidates
    ShoplineCustomer.where(id: candidate_customer_ids)
  end

  def confirm!(customer_id, user:, note: nil)
    customer_id = customer_id.to_i
    raise ArgumentError, "只能從候選名單確認" unless candidate_customer_ids.include?(customer_id)

    decide!("confirm", customer_id, user, note) do
      self.match_status = "verified"
      self.match_method = "manual"
      self.shopline_customer_id = customer_id
    end
  end

  # 排除一位候選；之後同步不會再提出這個人
  def reject!(customer_id, user:, note: nil)
    customer_id = customer_id.to_i
    decide!("reject", customer_id, user, note) do
      self.rejected_customer_ids = (rejected_customer_ids + [customer_id]).uniq
      self.shopline_customer_id = nil if shopline_customer_id == customer_id
      self.match_status = "unmatched" if match_status == "verified"
      refresh_candidates
    end
  end

  # 解除已確認的關聯：那位顧客記為排除，其餘候選重新提出
  def unlink!(user:, note: nil)
    raise ArgumentError, "還沒有已確認的關聯" unless verified?

    customer_id = shopline_customer_id
    decide!("unlink", customer_id, user, note) do
      self.rejected_customer_ids = (rejected_customer_ids + [customer_id]).uniq
      self.shopline_customer_id = nil
      self.match_status = "unmatched"
      refresh_candidates
    end
  end

  # 系統觀測到一次互動：最早的那次記為「首次已觀測」，之後的互動不覆蓋
  def observe_interaction!(at, source)
    return if at.nil? || (first_observed_at && first_observed_at <= at)

    update_columns(first_observed_at: at, first_observed_source: source.presence)
  end

  private

  def normalize_ig_username
    self.ig_username = ShoplineCustomer.normalize_ig(ig_username)
  end

  def refresh_candidates
    return if verified?

    self.ig_username = ShoplineCustomer.normalize_ig(ig_username)
    ids = self.class.candidate_ids_for_ig(ig_username) - rejected_customer_ids
    self.candidate_customer_ids = ids
    self.match_status = ids.any? ? "candidate" : "unmatched"
    self.match_method = if !self.class.valid_ig?(ig_username) then "invalid_ig"
                        elsif ids.size > 1 then "ig_multiple"
                        elsif ids.any? then (match_method == "legacy_auto" ? "legacy_auto" : "ig_exact")
                        end
  end

  def decide!(action, customer_id, user, note)
    from = match_status
    transaction do
      yield
      self.match_decided_by_user_id = user&.id
      self.match_decided_at = Time.current
      save!
      manychat_match_logs.create!(action: action, shopline_customer_id: customer_id, user_id: user&.id,
                                  from_status: from, to_status: match_status, note: note.presence,
                                  created_at: Time.current)
    end
  end
end
