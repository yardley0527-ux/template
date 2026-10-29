# KOC 名單（Koc 與各品牌 KOC）共用：公關品可分多次寄出，每次一筆 KocGiftShipment
module GiftShippable
  extend ActiveSupport::Concern

  included do
    has_many :gift_shipments, -> { order(:shipped_on, :id) }, as: :recipient, class_name: "KocGiftShipment",
                                                             dependent: :delete_all
  end
end
