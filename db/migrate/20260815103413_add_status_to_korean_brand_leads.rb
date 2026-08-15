class AddStatusToKoreanBrandLeads < ActiveRecord::Migration[7.1]
  def up
    add_column :korean_brand_leads, :status, :string, null: false, default: "待聯絡"

    execute <<~SQL
      UPDATE korean_brand_leads
      SET status = CASE
        WHEN replied THEN '已回覆'
        WHEN contacted THEN '已聯絡・待回覆'
        ELSE '待聯絡'
      END
    SQL

    remove_column :korean_brand_leads, :contacted, :boolean
    remove_column :korean_brand_leads, :replied, :boolean
  end

  def down
    add_column :korean_brand_leads, :contacted, :boolean, null: false, default: false
    add_column :korean_brand_leads, :replied, :boolean, null: false, default: false

    execute <<~SQL
      UPDATE korean_brand_leads
      SET contacted = (status != '待聯絡'),
          replied = (status = '已回覆')
    SQL

    remove_column :korean_brand_leads, :status
  end
end
