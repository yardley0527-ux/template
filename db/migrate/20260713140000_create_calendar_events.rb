class CreateCalendarEvents < ActiveRecord::Migration[7.1]
  def change
    create_table :calendar_events do |t|
      t.string :title, null: false
      t.string :event_type, null: false, default: "other"
      t.date :event_date, null: false
      t.string :time_info
      t.text :description
      t.string :departments, array: true, default: [], null: false

      t.timestamps
    end

    add_index :calendar_events, :event_date
  end
end
