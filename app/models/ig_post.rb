class IgPost < ApplicationRecord
  belongs_to :ig_profile

  def ig_url
    "https://www.instagram.com/p/#{shortcode}/"
  end
end
