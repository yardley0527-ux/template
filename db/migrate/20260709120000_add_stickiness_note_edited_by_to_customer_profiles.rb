class AddStickinessNoteEditedByToCustomerProfiles < ActiveRecord::Migration[7.1]
  def change
    add_column :customer_profiles, :stickiness_note_edited_by, :string
  end
end
