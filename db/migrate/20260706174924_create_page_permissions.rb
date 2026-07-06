class CreatePagePermissions < ActiveRecord::Migration[7.1]
  def change
    create_table :page_permissions do |t|
      t.references :role, null: false, foreign_key: true
      t.string :controller_name, null: false

      t.timestamps
    end
    add_index :page_permissions, [:role_id, :controller_name],
              unique: true, name: "index_page_permissions_on_role_and_controller"
  end
end
