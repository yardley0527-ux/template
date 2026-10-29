# KOC 公關品可能分多次寄出（看第一次成效再決定要不要寄第二次），
# 原本 kocs.pr_gift_shipped_at 只能記一次，改成一次寄送一筆紀錄。
# kocs.pr_gift_shipped_at 保留，存「最近一次寄出日期」，由 KocGiftShipment 自動同步，
# 讓既有的「已寄公關品」篩選與統計不用改。
class CreateKocGiftShipments < ActiveRecord::Migration[7.1]
  def up
    create_table :koc_gift_shipments do |t|
      t.references :koc, null: false, foreign_key: { on_delete: :cascade }
      t.date :shipped_on, null: false
      t.string :items                 # 寄了什麼，例如「代謝錠x1」
      t.text :notes                   # 這次寄送的目的或備註，例如「看第一次成效後加寄」
      t.bigint :created_by_user_id
      t.timestamps
    end
    add_index :koc_gift_shipments, %i[koc_id shipped_on]

    # 既有的一次寄出日期轉成第一筆紀錄；當時物流部備註寫的就是寄出品項，一起帶入
    execute <<~SQL
      INSERT INTO koc_gift_shipments (koc_id, shipped_on, items, created_at, updated_at)
      SELECT id, pr_gift_shipped_at, NULLIF(TRIM(logistics_notes), ''), NOW(), NOW()
      FROM kocs WHERE pr_gift_shipped_at IS NOT NULL
    SQL
  end

  def down
    drop_table :koc_gift_shipments
  end
end
