class AddTaggedAndNoteToTagExtractionRuns < ActiveRecord::Migration[7.1]
  def change
    add_column :tag_extraction_runs, :tagged, :boolean, default: false, null: false
    add_column :tag_extraction_runs, :note, :string
  end
end
