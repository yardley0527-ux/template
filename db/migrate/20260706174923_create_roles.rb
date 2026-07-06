class CreateRoles < ActiveRecord::Migration[7.1]
  def change
    create_table :roles do |t|
      t.string :key, null: false
      t.string :name, null: false

      t.timestamps
    end
    add_index :roles, :key, unique: true
  end
end
