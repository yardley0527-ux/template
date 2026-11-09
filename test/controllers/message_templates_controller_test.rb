# frozen_string_literal: true

require "test_helper"

class MessageTemplatesControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    role = Role.find_or_create_by!(key: "admin") { |r| r.name = "Admin" }
    sign_in User.create!(email: "tpl_admin@test.com", username: "tpl_admin", password: "password123", role: role)
  end

  def add_template(title, position: 0, subcategory: "白卡")
    template = MessageTemplate.create!(category_key: "upgrade", subcategory: subcategory, title: title, position: position)
    block = template.message_template_blocks.create!(block_type: "images", position: 0)
    block.message_template_images.create!(cloudinary_public_id: "id-#{title}", url: "https://example.com/#{title}.jpg", position: 0)
  end

  def template_query_count
    count = 0
    callback = lambda do |*, payload|
      count += 1 if payload[:sql].include?("message_template") && !payload[:cached]
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { get message_templates_path }
    assert_response :success
    count
  end

  test "範本增加時查詢次數不變" do
    add_template("第一則")
    before = template_query_count

    5.times { |i| add_template("多的#{i}", position: i + 1) }

    assert_equal before, template_query_count
  end

  test "範本依分類與排序顯示，含區塊圖片" do
    add_template("後面", position: 2)
    add_template("前面", position: 1)
    add_template("銀卡範本", subcategory: "銀卡")

    get message_templates_path

    assert_response :success
    assert_operator response.body.index("前面"), :<, response.body.index("後面")
    assert_includes response.body, "https://example.com/銀卡範本.jpg"
  end
end
