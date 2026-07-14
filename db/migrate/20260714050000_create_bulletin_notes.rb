class CreateBulletinNotes < ActiveRecord::Migration[7.1]
  def change
    create_table :bulletin_notes do |t|
      t.text :content, null: false
      t.boolean :done, null: false, default: false
      t.string :created_by
      t.datetime :done_at

      t.timestamps
    end

    add_index :bulletin_notes, [:done, :created_at]
  end
end
