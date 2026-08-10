class AddAiInsightToCustomerProfiles < ActiveRecord::Migration[7.1]
  def change
    add_column :customer_profiles, :black_gold_ai_watch, :jsonb, default: [], null: false
    add_column :customer_profiles, :black_gold_ai_next_actions, :jsonb, default: [], null: false
    add_column :customer_profiles, :black_gold_ai_generated_at, :datetime
    add_column :customer_profiles, :black_gold_ai_for_order_date, :date
  end
end
