# frozen_string_literal: true

require "test_helper"

# Relove/Body Goals/好好生醫/Dianbopopo/微電流面膜 這 5 個品牌業配名單頁補上的
# 「發送訊息內容」功能——每個品牌各自一張獨立的 xxx_koc_message_templates 表，
# 這裡確認 5 個頁面都能顯示、儲存，而且彼此不會共用到同一筆資料。
class BrandKocMessageTemplatesTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  BRANDS = [
    { index_path: :relove_kocs_path,      update_path: :message_template_relove_kocs_path,      model: ReloveKocMessageTemplate },
    { index_path: :body_goals_kocs_path,  update_path: :message_template_body_goals_kocs_path,  model: BodyGoalsKocMessageTemplate },
    { index_path: :betterbio_kocs_path,   update_path: :message_template_betterbio_kocs_path,   model: BetterbioKocMessageTemplate },
    { index_path: :dianbopopo_kocs_path,  update_path: :message_template_dianbopopo_kocs_path,  model: DianbopopoKocMessageTemplate },
    { index_path: :akimia_kocs_path,      update_path: :message_template_akimia_kocs_path,      model: AkimiaKocMessageTemplate }
  ].freeze

  setup do
    admin_role = Role.find_or_create_by!(key: "admin") { |r| r.name = "Admin" }
    @admin = User.create!(email: "brand_koc_admin@test.com", username: "brand_koc_admin", password: "password123", role: admin_role)
    sign_in @admin
  end

  test "each brand page shows its own 發送訊息內容 card and can save independently" do
    BRANDS.each do |brand|
      get public_send(brand[:index_path])
      assert_response :success
      assert_includes response.body, "發送訊息內容"

      patch public_send(brand[:update_path]), params: { content: "#{brand[:model]} 測試內容" }
      assert_equal "#{brand[:model]} 測試內容", brand[:model].current.content
    end

    # 各品牌互不共用同一筆 record
    contents = BRANDS.map { |b| b[:model].current.content }
    assert_equal contents.uniq.size, contents.size, "各品牌訊息內容不應互相覆蓋"
  end
end
