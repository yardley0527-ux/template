class AddHiddenAndVideoShootStatusToKocs < ActiveRecord::Migration[7.1]
  def change
    add_column :kocs, :hidden, :boolean, default: false, null: false
    add_column :kocs, :video_shoot_status, :string, default: "未拍攝", null: false
  end
end
