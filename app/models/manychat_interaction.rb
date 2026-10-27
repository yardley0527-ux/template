# ManyChat 單次互動，見 CreateManychatInteractions migration 說明。
class ManychatInteraction < ApplicationRecord
  belongs_to :manychat_subscriber
end
