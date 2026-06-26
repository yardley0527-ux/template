if MessageTemplate.any?
  puts "Message templates already seeded, skipping"
else

require 'yaml'
data = YAML.load_file(Rails.root.join('config/message_templates.yml'))

data['categories'].each do |cat|
  key = cat['key']
  if cat['subcategories']
    cat['subcategories'].each do |sub|
      sub['messages'].each_with_index do |content, i|
        tpl = MessageTemplate.create!(category_key: key, subcategory: sub['name'], position: i)
        tpl.message_template_blocks.create!(block_type: 'text', content: content, position: 0)
      end
    end
  else
    cat['messages'].each_with_index do |msg, i|
      tpl = MessageTemplate.create!(category_key: key, title: msg['title'], position: i)
      tpl.message_template_blocks.create!(block_type: 'text', content: msg['content'], position: 0)
    end
  end
end

  puts "Seeded #{MessageTemplate.count} message templates"
end
