class AddExternalKeyToCalendarEvents < ActiveRecord::Migration[7.1]
  def change
    add_column :calendar_events, :external_key, :string
    add_index :calendar_events, :external_key, unique: true
  end
end
