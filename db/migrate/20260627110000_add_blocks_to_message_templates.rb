class AddBlocksToMessageTemplates < ActiveRecord::Migration[7.1]
  def up
    create_table :message_template_blocks do |t|
      t.references :message_template, null: false, foreign_key: true
      t.string  :block_type, null: false, default: "text"  # "text" | "images"
      t.text    :content
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :message_template_blocks, [:message_template_id, :position]

    # Move images from template → block
    add_reference :message_template_images, :message_template_block, foreign_key: true

    # Convert existing content → text block (use raw SQL to avoid model caching issues)
    now = Time.current
    execute <<~SQL
      INSERT INTO message_template_blocks (message_template_id, block_type, content, position, created_at, updated_at)
      SELECT id, 'text', content, 0, '#{now}', '#{now}'
      FROM message_templates
      WHERE content IS NOT NULL AND content != ''
    SQL

    remove_reference :message_template_images, :message_template, foreign_key: true
    remove_column :message_templates, :content
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
