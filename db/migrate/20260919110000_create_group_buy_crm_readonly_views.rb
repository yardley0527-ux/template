# Read-only SQL views for the separate group-buy-crm app (docs/group_buy_crm_views.md).
#
# The views live in their own schema so the dedicated read-only role only ever needs
# USAGE on `group_buy_crm` and SELECT on these three views - never on shopline_customers,
# shopline_orders, customer_profiles or any other base table (views run with the owner's
# privileges).
#
# The role itself is NOT created here (Render's database user may lack CREATEROLE, and the
# password must never live in a migration or the repo): run db/ops/group_buy_crm_readonly_role.sql
# by hand. This migration only GRANTs when that role already exists.
class CreateGroupBuyCrmReadonlyViews < ActiveRecord::Migration[7.1]
  ROLE = "group_buy_crm_ro"

  def up
    create_schema "group_buy_crm"

    # Order matters: members and member_product_summaries read from member_order_lines.
    create_view "group_buy_crm.member_order_lines",       version: 1
    create_view "group_buy_crm.member_product_summaries", version: 1
    create_view "group_buy_crm.members",                  version: 1

    execute <<~SQL
      DO $$
      BEGIN
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = '#{ROLE}') THEN
          GRANT USAGE ON SCHEMA group_buy_crm TO #{ROLE};
          GRANT SELECT ON group_buy_crm.members,
                          group_buy_crm.member_order_lines,
                          group_buy_crm.member_product_summaries TO #{ROLE};
        END IF;
      END
      $$;
    SQL
  end

  def down
    # Reverse dependency order. Dropping the views/schema also drops the role's grants on them.
    drop_view "group_buy_crm.members"
    drop_view "group_buy_crm.member_product_summaries"
    drop_view "group_buy_crm.member_order_lines"

    drop_schema "group_buy_crm"
  end
end
