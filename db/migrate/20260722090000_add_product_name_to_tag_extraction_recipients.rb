class AddProductNameToTagExtractionRecipients < ActiveRecord::Migration[7.1]
  def change
    add_column :tag_extraction_recipients, :product_name, :string
  end
end
