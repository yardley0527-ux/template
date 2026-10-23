# 每個群組各自訂閱要收哪些報告（seo_daily、order_brief…），不再所有群組收一樣的。
# 既有群組都是為了 SEO 日報加的，補上 seo_daily 維持原本行為。
class AddSubscriptionsToLineBotGroups < ActiveRecord::Migration[7.1]
  def up
    add_column :line_bot_groups, :subscriptions, :string, array: true, null: false, default: []
    execute "UPDATE line_bot_groups SET subscriptions = '{seo_daily}'"

    # 同一份報告只發一次：import 可能一天跑好幾次，靠 unique index 擋重複推播
    create_table :line_digest_deliveries do |t|
      t.string  :topic, null: false
      t.date    :report_date, null: false
      t.integer :group_count, null: false, default: 0
      t.timestamps
    end
    add_index :line_digest_deliveries, [:topic, :report_date], unique: true
  end

  def down
    drop_table :line_digest_deliveries
    remove_column :line_bot_groups, :subscriptions
  end
end
