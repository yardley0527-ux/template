class CreateKolBuzzChecks < ActiveRecord::Migration[7.1]
  def change
    create_table :kol_buzz_checks do |t|
      t.references :kol_candidate, null: false, foreign_key: true
      t.string :source, null: false, default: "web"
      t.text :summary, null: false
      t.string :sentiment, null: false, default: "unknown"
      t.string :checked_by, null: false, default: "claude_websearch"
      t.datetime :checked_at, null: false
      t.jsonb :raw_links, null: false, default: []

      t.timestamps
    end
  end
end
