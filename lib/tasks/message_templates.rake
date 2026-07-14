namespace :message_templates do
  desc "Seed 升級訊息（upgrade）分類的公版訊息，可重複執行"
  task seed_upgrade: :environment do
    data = YAML.load_file(Rails.root.join("config/upgrade_message_templates.yml"))

    data["subcategories"].each do |sub|
      sub["messages"].each_with_index do |msg, i|
        tpl = MessageTemplate.find_or_initialize_by(
          category_key: "upgrade",
          subcategory:  sub["name"],
          title:        msg["title"]
        )
        tpl.position = i
        tpl.save!

        block = tpl.message_template_blocks.first ||
                tpl.message_template_blocks.build(block_type: "text", position: 0)
        block.update!(content: msg["content"])
      end
    end

    puts "upgrade templates: #{MessageTemplate.where(category_key: 'upgrade').count}"
  end
end
