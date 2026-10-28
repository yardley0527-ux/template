# ManyChat 訂閱者身分比對的人工操作紀錄（確認／排除／解除），見 AddIdentityMatchingToManychatSubscribers。
class ManychatMatchLog < ApplicationRecord
  ACTIONS = { "confirm" => "確認", "reject" => "排除候選", "unlink" => "解除關聯" }.freeze

  belongs_to :manychat_subscriber
  belongs_to :user, optional: true

  validates :action, inclusion: { in: ACTIONS.keys }
end
