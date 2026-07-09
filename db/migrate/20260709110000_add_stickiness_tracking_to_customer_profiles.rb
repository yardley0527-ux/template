# frozen_string_literal: true

# 黏著度分析的追蹤欄位：跟破8000的 OrderGiftRecord#follow_up_note 分開記，
# 黏著度是客人層級的追蹤，備註第一次填寫時記下追蹤時間，回購判斷以此時間為準
class AddStickinessTrackingToCustomerProfiles < ActiveRecord::Migration[7.1]
  def change
    add_column :customer_profiles, :stickiness_note, :text
    add_column :customer_profiles, :stickiness_followed_up_at, :datetime
  end
end
