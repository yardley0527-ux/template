class AddFollowUpToKoreanBrandLeads < ActiveRecord::Migration[7.1]
  def change
    add_column :korean_brand_leads, :follow_up, :text
  end
end
