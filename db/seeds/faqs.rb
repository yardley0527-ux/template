if FaqCategory.any?
  puts "FAQ categories already seeded, skipping"
else

require 'yaml'
data = YAML.load_file(Rails.root.join('config/faqs.yml'))

data['categories'].each_with_index do |cat, cat_i|
  category = FaqCategory.create!(name: cat['name'], position: cat_i)
  cat['faqs'].each_with_index do |faq, faq_i|
    category.faqs.create!(question: faq['question'], answer: faq['answer'], position: faq_i)
  end
end

  puts "Seeded #{FaqCategory.count} FAQ categories, #{Faq.count} FAQs"
end
