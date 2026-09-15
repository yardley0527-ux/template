# frozen_string_literal: true

class CreateWeeklyBriefings < ActiveRecord::Migration[7.1]
  def change
    create_table :weekly_briefings do |t|
      t.date :week_start, null: false
      t.date :week_end, null: false
      t.string :status, null: false, default: "pending"
      t.jsonb :metrics, null: false, default: {}
      t.jsonb :ai_report, null: false, default: {}
      t.text :error_message
      t.string :model
      t.string :prompt_version
      t.datetime :generated_at
      t.jsonb :meta, null: false, default: {}

      t.timestamps
    end

    add_index :weekly_briefings, :week_start, unique: true
  end
end
