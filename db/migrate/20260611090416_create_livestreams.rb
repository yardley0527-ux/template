class CreateLivestreams < ActiveRecord::Migration[7.1]
  def change
    create_table :livestreams do |t|
      t.date :date, null: false
      t.text :notes

      t.timestamps
    end
    add_index :livestreams, :date, unique: true
  end
end
