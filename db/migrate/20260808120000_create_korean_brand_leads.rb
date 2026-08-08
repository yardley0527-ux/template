class CreateKoreanBrandLeads < ActiveRecord::Migration[7.1]
  def change
    create_table :korean_brand_leads do |t|
      t.string :product_name, null: false
      t.string :source_url
      t.string :contact_channel
      t.boolean :contacted, null: false, default: false
      t.date :contacted_at
      t.text :email_content
      t.boolean :replied, null: false, default: false
      t.text :notes

      t.timestamps
    end
  end
end
