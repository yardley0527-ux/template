class CreateMembershipLevelChanges < ActiveRecord::Migration[7.1]
  def change
    create_table :membership_level_changes do |t|
      t.references :import_run, null: false, foreign_key: true
      t.string  :shopline_id
      t.string  :full_name
      t.string  :email
      t.string  :from_level, null: false
      t.string  :to_level,   null: false
      t.string  :direction,  null: false  # 'upgrade' | 'downgrade'
      t.datetime :changed_at, null: false
    end

    add_index :membership_level_changes, :shopline_id
    add_index :membership_level_changes, :direction
    add_index :membership_level_changes, :changed_at
  end
end
