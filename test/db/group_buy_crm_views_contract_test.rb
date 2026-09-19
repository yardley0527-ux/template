# frozen_string_literal: true

require_relative "group_buy_crm_view_test_helper"
require Rails.root.join("db/migrate/20260919110000_create_group_buy_crm_readonly_views")

# The three views are a contract with the separate group-buy-crm app: an unreviewed extra column
# would leak data across the boundary, a missing one would break that app. Keep these exact.
class GroupBuyCrmViewsContractTest < ActiveSupport::TestCase
  include GroupBuyCrmViewTestHelper

  EXPECTED_COLUMNS = {
    "members" => %w[shopline_customer_id shopline_id name email normalized_email membership_level total_amount
                    blacklisted membership_expiry_date joined_at credits points last_order_date],
    "member_order_lines" => %w[order_line_key shopline_customer_id customer_link_source email_consistent order_number
                               order_date raw_product_name mapping_status mapping_candidate_count product_key
                               product_label bundle_component_keys line_quantity source_line_count],
    "member_product_summaries" => %w[shopline_customer_id product_key product_label mapping_status order_count
                                     first_order_date last_order_date]
  }.freeze

  # Personal / financial / operational columns of shopline_customers & shopline_orders that must never cross the boundary.
  FORBIDDEN_COLUMNS = %w[phone mobile_phone country_code recipient_name recipient_phone address_1 address_2 city state
                         postal_code country birthdate gender facebook_id line_id instagram_account tags notes
                         personal_note referrer_name referrer_email referrer_phone utm_source utm_medium utm_campaign
                         checkout_amount payment_method payment_status encrypted_password].freeze

  def view_columns(view)
    ActiveRecord::Base.connection.select_values(<<~SQL)
      SELECT column_name FROM information_schema.columns
      WHERE table_schema = 'group_buy_crm' AND table_name = #{ActiveRecord::Base.connection.quote(view)}
      ORDER BY ordinal_position
    SQL
  end

  def schema_objects
    ActiveRecord::Base.connection.select_rows(<<~SQL).to_h { |name, kind| [name, kind] }
      SELECT c.relname, c.relkind FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'group_buy_crm'
    SQL
  end

  test "each view exposes exactly the contracted columns, in order" do
    EXPECTED_COLUMNS.each do |view, columns|
      assert_equal columns, view_columns(view), "#{view} columns drifted from the contract"
    end
  end

  test "no personal or financial column of the base tables leaks through any view" do
    leaked = EXPECTED_COLUMNS.keys.flat_map { |v| view_columns(v) } & FORBIDDEN_COLUMNS
    assert_empty leaked
  end

  test "the schema contains exactly the three views and nothing else" do
    assert_equal EXPECTED_COLUMNS.keys.sort, schema_objects.keys.sort
    assert_equal ["v"], schema_objects.values.uniq
  end

  test "views run with the owner's privileges (no security_invoker), so the read-only role needs no base-table access" do
    reloptions = ActiveRecord::Base.connection.select_values(<<~SQL)
      SELECT reloptions::text FROM pg_class
      WHERE oid IN ('group_buy_crm.members'::regclass, 'group_buy_crm.member_order_lines'::regclass,
                    'group_buy_crm.member_product_summaries'::regclass)
    SQL
    assert_equal [nil, nil, nil], reloptions
  end

  test "every object the view SQL references is schema-qualified" do
    files = Dir[Rails.root.join("db/views/group_buy_crm_*_v01.sql")]
    assert_equal 3, files.size
    files.each do |path|
      sql = File.read(path).gsub(/--.*$/, "") # drop comments (none of these files has "--" inside a string literal)
      referenced = sql.scan(/\b(?:FROM|JOIN)\s+(?!public\.|group_buy_crm\.|pg_catalog\.|\()([a-z_]+)/i).flatten.map(&:downcase).uniq
      ctes = sql.scan(/(?:\A|^|,|\bWITH)\s*([a-z_]+)\s+AS\s*\(/i).flatten.map(&:downcase).uniq
      unqualified = referenced - ctes - %w[lateral] # LATERAL is a keyword, not a relation
      assert_empty unqualified, "#{File.basename(path)} references unqualified relations: #{unqualified.inspect}"
    end
  end

  test "db/schema.rb dumps the schema and all three views (so schema:load recreates them)" do
    schema = File.read(Rails.root.join("db/schema.rb"))
    assert_includes schema, 'create_schema "group_buy_crm"'
    EXPECTED_COLUMNS.each_key { |v| assert_includes schema, %(create_view "group_buy_crm.#{v}") }
  end

  test "views loaded from db/schema.rb are identical to views created from db/views (dump/load round trip)" do
    # schema:load and migrate must give the same views. Raw control characters (e.g. a CR inside a string literal)
    # are silently normalized when Ruby reads schema.rb, which would make the two differ.
    definitions = lambda do
      EXPECTED_COLUMNS.keys.index_with do |view|
        ActiveRecord::Base.connection.select_value("SELECT pg_get_viewdef('group_buy_crm.#{view}'::regclass)")
      end
    end
    as_loaded = definitions.call

    ActiveRecord::Migration.suppress_messages do
      migration = CreateGroupBuyCrmReadonlyViews.new
      migration.migrate(:down)
      migration.migrate(:up) # created from the db/views files
    end

    assert_equal as_loaded, definitions.call
  end

  test "the stored view definitions contain no raw control characters (they do not survive the schema.rb round trip)" do
    EXPECTED_COLUMNS.each_key do |view|
      definition = ActiveRecord::Base.connection.select_value("SELECT pg_get_viewdef('group_buy_crm.#{view}'::regclass)")
      assert_no_match(/[\x00-\x08\x0B-\x1F\x7F]/, definition, "#{view} contains a raw control character (other than TAB/LF)")
      assert_no_match(/\r/, definition, "#{view} contains a raw CR")
    end
  end

  test "the migration is reversible: down removes everything, up recreates the same contract" do
    migration = CreateGroupBuyCrmReadonlyViews.new

    ActiveRecord::Migration.suppress_messages do
      migration.migrate(:down)
      assert_empty schema_objects, "down should remove all three views"
      assert_equal 0, ActiveRecord::Base.connection.select_value("SELECT count(*) FROM pg_namespace WHERE nspname = 'group_buy_crm'")

      migration.migrate(:up)
    end

    EXPECTED_COLUMNS.each { |view, columns| assert_equal columns, view_columns(view) }
  end

  test "the migration GRANTs to group_buy_crm_ro only when that role already exists (and never on base tables)" do
    conn = ActiveRecord::Base.connection
    can_create = conn.select_value("SELECT rolcreaterole OR rolsuper FROM pg_roles WHERE rolname = current_user")
    skip "current database user cannot create roles" unless can_create
    skip "group_buy_crm_ro already exists in this cluster; not touching a real role" if conn.select_value("SELECT 1 FROM pg_roles WHERE rolname = 'group_buy_crm_ro'")

    conn.execute("CREATE ROLE group_buy_crm_ro NOLOGIN") # rolled back with the test transaction
    ActiveRecord::Migration.suppress_messages do
      migration = CreateGroupBuyCrmReadonlyViews.new
      migration.migrate(:down)
      migration.migrate(:up)
    end

    priv = ->(sql) { conn.select_value(sql) }
    assert_equal true, priv.call("SELECT has_schema_privilege('group_buy_crm_ro', 'group_buy_crm', 'USAGE')")
    EXPECTED_COLUMNS.each_key do |v|
      assert_equal true,  priv.call("SELECT has_table_privilege('group_buy_crm_ro', 'group_buy_crm.#{v}', 'SELECT')")
      assert_equal false, priv.call("SELECT has_table_privilege('group_buy_crm_ro', 'group_buy_crm.#{v}', 'INSERT')")
    end
    %w[shopline_customers shopline_orders customer_profiles product_name_mappings crm_products users].each do |t|
      assert_equal false, priv.call("SELECT has_table_privilege('group_buy_crm_ro', 'public.#{t}', 'SELECT')"), "role must not read #{t}"
    end
    assert_equal false, priv.call("SELECT has_schema_privilege('group_buy_crm_ro', 'group_buy_crm', 'CREATE')")
  end
end
