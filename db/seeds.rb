# This file should contain all the record creation needed to seed the database with its default values.
# The data can then be loaded with the rails db:seed command (or created alongside the database with db:setup).
#
# Examples:
#
#   movies = Movie.create([{ name: 'Star Wars' }, { name: 'Lord of the Rings' }])
#   Character.create(name: 'Luke', movie: movies.first)

load Rails.root.join("db/seeds/livestreams.rb")
load Rails.root.join("db/seeds/message_templates.rb")
load Rails.root.join("db/seeds/faqs.rb")
load Rails.root.join("db/seeds/korean_brand_leads.rb")
