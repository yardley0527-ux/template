class CreateDailyBriefings < ActiveRecord::Migration[7.1]
  def change
    create_table :daily_briefings do |t|
      t.date :briefing_date, null: false
      t.string :status, null: false, default: "pending"
      t.jsonb :summary, null: false, default: []
      t.jsonb :dropped_balls, null: false, default: []
      t.jsonb :pending_decisions, null: false, default: []
      t.text :error_message
      t.datetime :generated_at
      t.jsonb :meta, null: false, default: {}

      t.timestamps
    end

    add_index :daily_briefings, :briefing_date, unique: true
  end
end
