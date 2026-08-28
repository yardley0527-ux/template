# PaperTrail 加進 CrmProduct/CrmLivestreamOutreachTask 時（0fd2a56）沒有補上
# 這張表的 migration——當時說法是「本機 dev DB 早就有這張表了，schema 相容」，
# 但那只是本機一直沒被清掉的殘留，從沒真正被 migration 建過。正式站沒有這張
# 表，導致任何 has_paper_trail model 的 update 都會噴 PG::UndefinedTable。
# 用 table_exists? 擋一下，因為某些本機/共用 dev DB 可能已經有這張表了。
class CreateVersions < ActiveRecord::Migration[7.1]
  def change
    return if table_exists?(:versions)

    create_table :versions do |t|
      t.string   :item_type, null: false
      t.bigint   :item_id,   null: false
      t.string   :event,     null: false
      t.string   :whodunnit
      t.text     :object
      t.datetime :created_at, precision: nil
      t.text     :object_changes
    end
    add_index :versions, [:item_type, :item_id]
  end
end
