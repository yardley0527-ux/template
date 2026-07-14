class AddDepartmentToBulletinNotes < ActiveRecord::Migration[7.1]
  def change
    # NULL = 全公司板（首頁）；有值 = 該部門的板
    add_column :bulletin_notes, :department, :string
    add_index :bulletin_notes, [:department, :done, :created_at]
  end
end
