# frozen_string_literal: true

# 黏著度分析的「已維護」勾選欄位，只有 Admin（owner）可編輯
class AddStickinessMaintainedToCustomerProfiles < ActiveRecord::Migration[7.1]
  def change
    add_column :customer_profiles, :stickiness_maintained, :boolean, default: false, null: false
  end
end
