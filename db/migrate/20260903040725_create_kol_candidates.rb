class CreateKolCandidates < ActiveRecord::Migration[7.1]
  def change
    create_table :kol_candidates do |t|
      t.string :name, null: false
      t.string :campaign
      t.string :status, null: false, default: "待接洽"
      t.string :instagram_handle
      t.string :tiktok_handle
      t.string :youtube_handle
      t.text :bio
      t.string :content_tags
      t.string :contact_email
      t.string :contact_line_id
      t.text :notes

      t.timestamps
    end

    add_index :kol_candidates, :status
  end
end
