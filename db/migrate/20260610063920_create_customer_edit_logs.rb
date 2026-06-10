class CreateCustomerEditLogs < ActiveRecord::Migration[7.1]
  def change
    create_table :customer_edit_logs do |t|
      t.bigint :customer_id
      t.bigint :user_id
      t.string :customer_name
      t.string :section
      t.jsonb :changes_json

      t.timestamps
    end
    add_index :customer_edit_logs, :customer_id
    add_index :customer_edit_logs, :created_at
  end
end
