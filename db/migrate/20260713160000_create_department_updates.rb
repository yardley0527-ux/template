class CreateDepartmentUpdates < ActiveRecord::Migration[7.1]
  def change
    create_table :department_updates do |t|
      t.string :department, null: false
      t.date :log_date, null: false
      t.text :content

      t.timestamps
    end

    add_index :department_updates, [:department, :log_date], unique: true
    add_index :department_updates, :log_date
  end
end
