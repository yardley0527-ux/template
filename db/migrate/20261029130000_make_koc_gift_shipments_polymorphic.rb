# 各品牌 KOC 名單（ReloveKoc、BodyGoalsKoc…）跟 Koc 一樣會分多次寄公關品，
# 寄送紀錄改成共用一張表，用 recipient_type + recipient_id 指向哪一個品牌的哪一位 KOC。
# 各品牌既有的 pr_gift_shipped_at 轉成第一筆紀錄，物流部備註當作品項帶入（同 CreateKocGiftShipments）。
class MakeKocGiftShipmentsPolymorphic < ActiveRecord::Migration[7.1]
  BRAND_TABLES = {
    "ReloveKoc" => "relove_kocs", "BodyGoalsKoc" => "body_goals_kocs", "BetterbioKoc" => "betterbio_kocs",
    "DianbopopoKoc" => "dianbopopo_kocs", "AkimiaKoc" => "akimia_kocs", "MiraeKoc" => "mirae_kocs",
    "DecopopKoc" => "decopop_kocs"
  }.freeze

  def up
    add_column :koc_gift_shipments, :recipient_type, :string
    add_column :koc_gift_shipments, :recipient_id, :bigint
    execute "UPDATE koc_gift_shipments SET recipient_type = 'Koc', recipient_id = koc_id"
    change_column_null :koc_gift_shipments, :recipient_type, false
    change_column_null :koc_gift_shipments, :recipient_id, false
    remove_reference :koc_gift_shipments, :koc, index: true, foreign_key: { on_delete: :cascade }
    add_index :koc_gift_shipments, %i[recipient_type recipient_id shipped_on], name: "index_koc_gift_shipments_on_recipient"

    BRAND_TABLES.each do |type, table|
      execute <<~SQL
        INSERT INTO koc_gift_shipments (recipient_type, recipient_id, shipped_on, items, created_at, updated_at)
        SELECT '#{type}', id, pr_gift_shipped_at, NULLIF(TRIM(logistics_notes), ''), NOW(), NOW()
        FROM #{table} WHERE pr_gift_shipped_at IS NOT NULL
      SQL
    end
  end

  def down
    execute "DELETE FROM koc_gift_shipments WHERE recipient_type <> 'Koc'"
    add_reference :koc_gift_shipments, :koc, foreign_key: { on_delete: :cascade }
    execute "UPDATE koc_gift_shipments SET koc_id = recipient_id"
    change_column_null :koc_gift_shipments, :koc_id, false
    add_index :koc_gift_shipments, %i[koc_id shipped_on]
    remove_index :koc_gift_shipments, name: "index_koc_gift_shipments_on_recipient"
    remove_column :koc_gift_shipments, :recipient_type
    remove_column :koc_gift_shipments, :recipient_id
  end
end
