# frozen_string_literal: true

# PaperTrail's `versions` table is in db/schema.rb (used by CrmProduct's
# has_paper_trail for inventory-field audit history) but no migration ever
# created it — schema.rb was apparently generated once against a DB that had
# it from an out-of-band setup. Any environment bootstrapped via `db:migrate`
# instead of `db:schema:load` (production) never got this table, so every
# save on a has_paper_trail model 500s with PG::UndefinedTable. Guarded with
# table_exists? so environments that already have it (dev/test, loaded via
# schema:load) are unaffected.
class CreateVersions < ActiveRecord::Migration[7.1]
  def up
    return if table_exists?(:versions)

    create_table :versions do |t|
      t.string :item_type, null: false
      t.bigint :item_id, null: false
      t.string :event, null: false
      t.string :whodunnit
      t.text :object
      t.datetime :created_at, precision: nil
      t.text :object_changes
      t.index [:item_type, :item_id], name: "index_versions_on_item_type_and_item_id"
    end
  end

  def down
    drop_table :versions, if_exists: true
  end
end
