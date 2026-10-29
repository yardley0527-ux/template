# KOC 公關品寄送紀錄，一次寄出一筆，見 CreateKocGiftShipments migration 說明。
class KocGiftShipment < ApplicationRecord
  belongs_to :koc

  validates :shipped_on, presence: true

  after_commit :sync_koc_latest_date

  private

  # kocs.pr_gift_shipped_at 存最近一次寄出日期，供「已寄公關品」篩選與統計使用
  def sync_koc_latest_date
    return unless Koc.exists?(koc_id)

    Koc.where(id: koc_id).update_all(pr_gift_shipped_at: KocGiftShipment.where(koc_id: koc_id).maximum(:shipped_on))
  end
end
