# 某一天 IG 私訊的 AI 整理（總結＋建議新增的自動回覆／FAQ），見 IgInbox::Digest。
class IgInboxDigest < ApplicationRecord
  STATUSES = %w[pending done failed].freeze

  validates :day, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
end
