class AddIgFollowFlagsToReloveKocs < ActiveRecord::Migration[7.1]
  def change
    add_column :relove_kocs, :follows_chloe_ig, :boolean, default: false, null: false
    add_column :relove_kocs, :follows_official_ig, :boolean, default: false, null: false
  end
end
