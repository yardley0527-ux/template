# frozen_string_literal: true

require "test_helper"

class BulletinNotesControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = User.create!(email: "note@test.com", username: "serena_t", password: "password123")
    DepartmentSheetSync.mark_run! # 首頁載入不觸發真同步
    sign_in @user
  end

  test "creates a note with author and shows it on its department board" do
    assert_difference -> { BulletinNote.count }, 1 do
      post bulletin_notes_path, params: { bulletin_note: { content: "訂 7/17 直播贈品", department: "廣告部" } }
    end
    note = BulletinNote.last
    assert_equal "serena_t", note.created_by

    get department_board_path("廣告部")
    assert_includes response.body, "訂 7/17 直播贈品"
  end

  test "rejects blank content with an alert" do
    assert_no_difference -> { BulletinNote.count } do
      post bulletin_notes_path, params: { bulletin_note: { content: "   " } }
    end
    assert_redirected_to root_path
    assert flash[:alert].present?
  end

  test "toggle marks done with timestamp and back" do
    note = BulletinNote.create!(content: "測試")

    patch toggle_bulletin_note_path(note)
    assert note.reload.done?
    assert note.done_at.present?

    patch toggle_bulletin_note_path(note)
    assert_not note.reload.done?
    assert_nil note.done_at
  end

  test "destroy removes the note" do
    note = BulletinNote.create!(content: "刪我")
    assert_difference -> { BulletinNote.count }, -1 do
      delete bulletin_note_path(note)
    end
  end

  test "board purges done notes older than 14 days but keeps recent ones" do
    BulletinNote.create!(content: "老完成", done: true, done_at: 20.days.ago)
    BulletinNote.create!(content: "新完成", done: true, done_at: 2.days.ago)
    BulletinNote.create!(content: "未完成")

    board = BulletinNote.board
    contents = board.map(&:content)
    assert_includes contents, "未完成"
    assert_includes contents, "新完成"
    assert_not_includes contents, "老完成"
    assert_equal "未完成", board.first.content, "未完成的排前面"
  end

  test "department board shows only that department's notes plus its recent logs" do
    BulletinNote.create!(content: "廣告部的事", department: "廣告部")
    BulletinNote.create!(content: "全公司的事")
    BulletinNote.create!(content: "設計部的事", department: "設計部")
    DepartmentUpdate.create!(department: "廣告部", log_date: Date.current, content: "美白推播圖完成")

    get department_board_path("廣告部")

    assert_response :success
    assert_includes response.body, "廣告部佈告欄"
    assert_includes response.body, "廣告部的事"
    assert_not_includes response.body, "全公司的事"
    assert_not_includes response.body, "設計部的事"
    assert_includes response.body, "美白推播圖完成"
  end

  test "unknown department redirects home" do
    get department_board_path("不存在部")
    assert_redirected_to root_path
  end

  test "creating from a department board scopes and returns to that board" do
    post bulletin_notes_path, params: { bulletin_note: { content: "訂到貨箱", department: "物流部" } }

    note = BulletinNote.last
    assert_equal "物流部", note.department
    assert_redirected_to department_board_path("物流部")
  end

  test "invalid department on create falls back to the company board" do
    post bulletin_notes_path, params: { bulletin_note: { content: "亂填部門", department: "駭客部" } }

    assert_nil BulletinNote.last.department
    assert_redirected_to root_path
  end

  test "toggle on a department note returns to its board" do
    note = BulletinNote.create!(content: "部門便條", department: "CRM")
    patch toggle_bulletin_note_path(note)
    assert_redirected_to department_board_path("CRM")
  end

  test "homepage company board sits above department lights and excludes department notes" do
    BulletinNote.create!(content: "全公司的事")
    BulletinNote.create!(content: "廣告部板便條", department: "廣告部")

    get root_path
    assert_includes response.body, "公司佈告欄"
    assert_includes response.body, "全公司的事"
    assert_not_includes response.body, "廣告部板便條"
    assert_includes response.body, department_board_path("廣告部")
    assert_includes response.body, "📌1"
    assert_operator response.body.index("公司佈告欄"), :<, response.body.index("部門今日回報"),
                    "公司佈告欄要在部門今日回報上方"
  end

  test "department board shows fixed weekly and monthly sections" do
    get department_board_path("數據部")

    assert_response :success
    assert_includes response.body, "周待辦"
    assert_includes response.body, "月待辦"
    assert_includes response.body, "新增板子"
  end

  test "notes land in their section" do
    BulletinNote.create!(content: "週的事", department: "數據部", section: "周待辦")
    BulletinNote.create!(content: "月的事", department: "數據部", section: "月待辦")

    get department_board_path("數據部")
    body = response.body
    assert_operator body.index("週的事"), :>, body.index("周待辦")
    assert_operator body.index("週的事"), :<, body.index("月待辦")
    assert_operator body.index("月的事"), :>, body.index("月待辦")
  end

  test "creates a custom section and posts a note into it" do
    post department_board_sections_path("數據部"), params: { name: "omnichat 標籤確認事項" }
    assert_redirected_to department_board_path("數據部")
    assert BulletinSection.exists?(department: "數據部", name: "omnichat 標籤確認事項")

    post bulletin_notes_path, params: { bulletin_note: {
      content: "全能 b 群設 omnichat 自動回覆", department: "數據部", section: "omnichat 標籤確認事項"
    } }

    get department_board_path("數據部")
    assert_includes response.body, "omnichat 標籤確認事項"
    assert_includes response.body, "全能 b 群設 omnichat 自動回覆"
  end

  test "cannot create a section named after a fixed board or duplicate" do
    assert_no_difference -> { BulletinSection.count } do
      post department_board_sections_path("數據部"), params: { name: "周待辦" }
    end
    BulletinSection.create!(department: "數據部", name: "重複板")
    assert_no_difference -> { BulletinSection.count } do
      post department_board_sections_path("數據部"), params: { name: "重複板" }
    end
  end

  test "destroying a custom section removes its notes but not others" do
    section = BulletinSection.create!(department: "數據部", name: "omnichat 標籤確認事項")
    BulletinNote.create!(content: "板內便條", department: "數據部", section: "omnichat 標籤確認事項")
    keep = BulletinNote.create!(content: "周待辦便條", department: "數據部", section: "周待辦")

    assert_difference -> { BulletinNote.count }, -1 do
      delete board_section_path(section)
    end
    assert BulletinNote.exists?(keep.id)
    assert_not BulletinSection.exists?(section.id)
  end

  test "note without section defaults to weekly board" do
    post bulletin_notes_path, params: { bulletin_note: { content: "沒指定板", department: "數據部" } }
    assert_equal "周待辦", BulletinNote.last.section
  end

  test "works for a non-admin department account" do
    staff_role = Role.create!(key: "staff2", name: "Staff")
    staff = User.create!(email: "dept@test.com", username: "dept_t", password: "password123", role: staff_role)
    sign_in staff

    post bulletin_notes_path, params: { bulletin_note: { content: "部門帳號也能貼", department: "物流部" } }
    assert_redirected_to department_board_path("物流部")
    assert_equal "部門帳號也能貼", BulletinNote.last.content
  end
end
