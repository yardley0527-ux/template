# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.1].define(version: 2026_02_09_114928) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "admins", force: :cascade do |t|
    t.string "email"
    t.string "password_digest"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "health_assessment_products", force: :cascade do |t|
    t.bigint "shopline_customer_health_assessment_id", null: false
    t.bigint "product_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["product_id"], name: "index_health_assessment_products_on_product_id"
    t.index ["shopline_customer_health_assessment_id"], name: "idx_on_shopline_customer_health_assessment_id_6907628e29"
  end

  create_table "import_runs", force: :cascade do |t|
    t.string "kind", null: false
    t.string "file_name", null: false
    t.string "file_checksum", null: false
    t.jsonb "meta", default: {}, null: false
    t.integer "processed_rows", default: 0, null: false
    t.integer "upserted_rows", default: 0, null: false
    t.integer "skipped_rows", default: 0, null: false
    t.integer "error_rows", default: 0, null: false
    t.jsonb "error_messages", default: [], null: false
    t.datetime "started_at"
    t.datetime "finished_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["kind", "file_checksum"], name: "index_import_runs_on_kind_and_file_checksum"
  end

  create_table "products", force: :cascade do |t|
    t.string "name"
    t.string "category"
    t.string "status"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "shopline_customer_health_assessments", force: :cascade do |t|
    t.bigint "shopline_customer_id", null: false
    t.string "interaction_level"
    t.text "main_health_goal"
    t.text "summary_notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["shopline_customer_id"], name: "idx_on_shopline_customer_id_03d1184d99"
  end

  create_table "shopline_customer_health_questionnaires", force: :cascade do |t|
    t.bigint "shopline_customer_id", null: false
    t.integer "height_cm"
    t.decimal "weight_kg", precision: 5, scale: 1
    t.integer "body_fat_percentage"
    t.string "work_type"
    t.date "birthdate"
    t.string "marital_status"
    t.integer "family_members_count"
    t.text "family_members_details"
    t.string "sleep_time"
    t.string "wake_time"
    t.integer "water_intake_ml"
    t.string "diet_type", default: [], array: true
    t.boolean "take_chinese_medicine"
    t.boolean "bought_our_products"
    t.boolean "bought_other_supplements"
    t.text "previous_weight_loss_methods"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "purchase_reason"
    t.boolean "currently_weight_loss"
    t.string "diet_type_other"
    t.index ["shopline_customer_id"], name: "idx_on_shopline_customer_id_6d5178055d"
  end

  create_table "shopline_customers", force: :cascade do |t|
    t.string "shopline_id"
    t.string "full_name"
    t.string "email"
    t.datetime "joined_at"
    t.string "join_source"
    t.string "language"
    t.integer "order_count"
    t.decimal "total_amount", precision: 10, scale: 2
    t.decimal "issued_shopping_credits", precision: 10, scale: 2
    t.decimal "deducted_shopping_credits", precision: 10, scale: 2
    t.decimal "used_shopping_credits", precision: 10, scale: 2
    t.decimal "current_shopping_credits", precision: 10, scale: 2
    t.integer "issued_points"
    t.integer "deducted_points"
    t.integer "used_points"
    t.integer "current_points"
    t.boolean "is_member"
    t.datetime "member_registered_at"
    t.string "member_registration_source"
    t.string "facebook_id"
    t.string "line_id"
    t.boolean "blacklisted"
    t.boolean "has_password"
    t.boolean "accept_email_marketing"
    t.boolean "accept_sms_marketing"
    t.boolean "accept_fb_marketing"
    t.boolean "accept_line_marketing"
    t.boolean "accept_whatsapp_marketing"
    t.datetime "last_login_at"
    t.string "phone"
    t.string "country_code"
    t.string "mobile_phone"
    t.string "recipient_name"
    t.string "recipient_phone"
    t.string "address_1"
    t.string "address_2"
    t.string "city"
    t.string "state"
    t.string "postal_code"
    t.string "country"
    t.string "membership_level"
    t.date "membership_expiry_date"
    t.string "gender"
    t.date "birthdate"
    t.string "instagram_account"
    t.text "tags"
    t.text "notes"
    t.string "utm_source"
    t.string "utm_medium"
    t.string "utm_source_medium"
    t.string "utm_campaign"
    t.string "utm_term"
    t.string "utm_content"
    t.datetime "utm_clicked_at"
    t.string "referrer_name"
    t.string "referrer_email"
    t.string "referrer_phone"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "personal_note"
    t.bigint "import_run_id"
    t.string "source_row_hash"
    t.index ["email"], name: "index_shopline_customers_on_email"
    t.index ["import_run_id"], name: "index_shopline_customers_on_import_run_id"
    t.index ["shopline_id"], name: "index_shopline_customers_on_shopline_id"
    t.index ["source_row_hash"], name: "index_shopline_customers_on_source_row_hash", unique: true
  end

  create_table "shopline_orders", force: :cascade do |t|
    t.string "order_number"
    t.string "product_name"
    t.string "email"
    t.string "instagram_account"
    t.string "payment_status"
    t.string "order_status"
    t.decimal "total_amount", precision: 10, scale: 2
    t.integer "quantity"
    t.string "customer_name"
    t.string "payment_method"
    t.datetime "order_date"
    t.string "utm_source"
    t.string "utm_medium"
    t.string "utm_source_medium"
    t.string "utm_campaign"
    t.string "utm_term"
    t.string "utm_content"
    t.datetime "utm_clicked_at"
    t.string "membership_level"
    t.bigint "shopline_customer_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "import_run_id"
    t.integer "source_year"
    t.integer "source_month"
    t.string "source_row_hash"
    t.decimal "checkout_amount", precision: 10, scale: 2
    t.string "city"
    t.index ["checkout_amount"], name: "index_shopline_orders_on_checkout_amount"
    t.index ["city"], name: "index_shopline_orders_on_city"
    t.index ["email"], name: "index_shopline_orders_on_email"
    t.index ["import_run_id"], name: "index_shopline_orders_on_import_run_id"
    t.index ["shopline_customer_id"], name: "index_shopline_orders_on_shopline_customer_id"
    t.index ["source_row_hash"], name: "index_shopline_orders_on_source_row_hash", unique: true
    t.index ["source_year", "source_month"], name: "index_shopline_orders_on_source_year_and_source_month"
  end

  create_table "users", force: :cascade do |t|
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at"
    t.datetime "remember_created_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "username", default: "", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
    t.index ["username"], name: "index_users_on_username", unique: true
  end

  add_foreign_key "health_assessment_products", "products"
  add_foreign_key "health_assessment_products", "shopline_customer_health_assessments"
  add_foreign_key "shopline_customer_health_assessments", "shopline_customers"
  add_foreign_key "shopline_customer_health_questionnaires", "shopline_customers"
  add_foreign_key "shopline_orders", "shopline_customers"
end
