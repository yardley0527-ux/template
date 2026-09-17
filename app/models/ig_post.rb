class IgPost < ApplicationRecord
  belongs_to :ig_profile
  has_one :group_buy_detection, dependent: :destroy

  def ig_url
    url.presence || "https://www.instagram.com/p/#{shortcode}/"
  end

  def reel?
    product_type == "clips"
  end
end
