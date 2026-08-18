class AddVideoShootStatusToReloveKocs < ActiveRecord::Migration[7.1]
  def change
    add_column :relove_kocs, :video_shoot_status, :string, default: "未拍攝", null: false
  end
end
