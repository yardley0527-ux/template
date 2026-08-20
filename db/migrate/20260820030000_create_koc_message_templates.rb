class CreateKocMessageTemplates < ActiveRecord::Migration[7.1]
  def change
    create_table :koc_message_templates do |t|
      t.text :content, null: false, default: ""

      t.timestamps
    end
  end
end
