class AddBlackGoldNoteToCustomerProfiles < ActiveRecord::Migration[7.1]
  def change
    add_column :customer_profiles, :black_gold_note, :text
    add_column :customer_profiles, :black_gold_note_edited_by, :string
  end
end
