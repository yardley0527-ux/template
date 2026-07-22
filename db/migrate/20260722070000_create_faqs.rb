class CreateFaqs < ActiveRecord::Migration[7.1]
  def change
    create_table :faq_categories do |t|
      t.string  :name, null: false
      t.integer :position, default: 0, null: false
      t.timestamps
    end

    create_table :faqs do |t|
      t.references :faq_category, null: false, foreign_key: true
      t.text    :question, null: false
      t.text    :answer
      t.integer :position, default: 0, null: false
      t.timestamps
    end
    add_index :faqs, [:faq_category_id, :position]

    create_table :faq_images do |t|
      t.references :faq, null: false, foreign_key: true
      t.string  :cloudinary_public_id, null: false
      t.string  :url,                  null: false
      t.integer :position, default: 0, null: false
      t.timestamps
    end
  end
end
