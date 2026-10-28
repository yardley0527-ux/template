# 活動草稿名單的一個人；snapshot 是建立草稿當下的客群資料（身分、購買狀態、來源等）。
class MarketingCampaignDraftMember < ApplicationRecord
  belongs_to :marketing_campaign_draft
end
