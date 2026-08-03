class AddTaggedAndNoteToTagExtractionRecipients < ActiveRecord::Migration[7.1]
  def change
    add_column :tag_extraction_recipients, :tagged, :boolean, default: false, null: false
    add_column :tag_extraction_recipients, :note, :string
  end
end
