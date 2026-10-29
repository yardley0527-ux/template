# KOC 公關品寄送紀錄，一次寄出一筆；Koc 與各品牌 KOC 名單共用，
# 見 CreateKocGiftShipments / MakeKocGiftShipmentsPolymorphic migration 說明。
class KocGiftShipment < ApplicationRecord
  RECIPIENT_TYPES = %w[Koc ReloveKoc BodyGoalsKoc BetterbioKoc DianbopopoKoc AkimiaKoc MiraeKoc DecopopKoc].freeze

  belongs_to :recipient, polymorphic: true

  validates :shipped_on, presence: true
  validates :recipient_type, inclusion: { in: RECIPIENT_TYPES }

  after_commit :sync_recipient_latest_date

  private

  # 名單上的 pr_gift_shipped_at 存最近一次寄出日期，供「已寄公關品」篩選與統計使用
  def sync_recipient_latest_date
    latest = KocGiftShipment.where(recipient_type: recipient_type, recipient_id: recipient_id).maximum(:shipped_on)
    recipient_type.constantize.where(id: recipient_id).update_all(pr_gift_shipped_at: latest)
  end
end
