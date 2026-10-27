# ManyChat 訂閱者對應表，見 CreateManychatSubscribers migration 說明。
class ManychatSubscriber < ApplicationRecord
  belongs_to :shopline_customer, optional: true
  has_many :manychat_interactions, dependent: :delete_all

  # account_key 用該 IG 帳號名稱（如 shengting.slim）；不設白名單，新開的產品帳號直接能接。
  ACCOUNT_KEY_FORMAT = /\A[a-z0-9._]{1,30}\z/

  validates :account_key, format: { with: ACCOUNT_KEY_FORMAT }
  validates :subscriber_id, presence: true, uniqueness: { scope: :account_key }

  before_save :match_customer, if: -> { will_save_change_to_ig_username? || shopline_customer_id.nil? }

  # 同一個 IG 可能對到多筆客人（分身）；取累積消費最高的那筆。
  # 客人檔沒填 IG 的，再看訂單上填的 IG。
  def self.customer_id_for_ig(ig)
    return nil if ig.blank?

    ShoplineCustomer.where(instagram_account: ig).order(total_amount: :desc).pick(:id) ||
      ShoplineOrder.where(instagram_account: ig).where.not(shopline_customer_id: nil)
                   .order(id: :desc).pick(:shopline_customer_id)
  end

  private

  def match_customer
    self.ig_username = ShoplineCustomer.normalize_ig(ig_username)
    self.shopline_customer_id = self.class.customer_id_for_ig(ig_username)
  end
end
