class CreateMessageTemplates < ActiveRecord::Migration[7.1]
  def change
    create_table :message_templates do |t|
      t.string  :category_key,  null: false
      t.string  :subcategory
      t.string  :title
      t.text    :content
      t.integer :position, default: 0, null: false
      t.timestamps
    end

    add_index :message_templates, [:category_key, :subcategory, :position]

    create_table :message_template_images do |t|
      t.references :message_template, null: false, foreign_key: true
      t.string  :cloudinary_public_id, null: false
      t.string  :url,                  null: false
      t.integer :position, default: 0, null: false
      t.timestamps
    end
  end
end
