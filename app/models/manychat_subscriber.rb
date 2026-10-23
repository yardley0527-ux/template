# ManyChat 訂閱者對應表，見 CreateManychatSubscribers migration 說明。
class ManychatSubscriber < ApplicationRecord
  belongs_to :shopline_customer, optional: true

  validates :account_key, inclusion: { in: ManychatCheck::ACCOUNTS.keys }
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
