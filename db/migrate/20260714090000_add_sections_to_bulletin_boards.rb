class AddSectionsToBulletinBoards < ActiveRecord::Migration[7.1]
  def change
    # 部門板內的分板：周待辦/月待辦為固定板，此表存自訂板（如 omnichat 標籤確認事項）
    create_table :bulletin_sections do |t|
      t.string :department, null: false
      t.string :name, null: false
      t.timestamps
    end
    add_index :bulletin_sections, [:department, :name], unique: true

    add_column :bulletin_notes, :section, :string, null: false, default: "周待辦"
  end
end
