# frozen_string_literal: true

class CreateWeeklyBriefingTodos < ActiveRecord::Migration[7.1]
  def change
    create_table :weekly_briefing_todos do |t|
      t.references :weekly_briefing, null: false, foreign_key: true
      t.string :dedupe_key, null: false
      t.string :title, null: false
      t.text :description
      t.string :priority, null: false, default: "medium"
      t.string :suggested_role
      t.date :due_date
      t.text :data_issue
      t.text :target_segment
      t.jsonb :target_query, null: false, default: {}
      t.integer :target_count
      t.string :expected_kpi
      t.string :status, null: false, default: "pending"
      t.datetime :completed_at
      t.string :source, null: false, default: "weekly_briefing"

      t.timestamps
    end

    add_index :weekly_briefing_todos, %i[weekly_briefing_id dedupe_key],
              unique: true, name: "idx_wb_todos_on_briefing_and_dedupe"
  end
end
