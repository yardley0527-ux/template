# frozen_string_literal: true
#
# Pattern-A duplicate cleanup for shopline_orders (see
# ShoplineOrdersDedupeService for the exact matching rules). Dry-run by
# default; nothing is ever deleted unless APPLY=1 is explicitly set — there
# is no other way to trigger a write from this task.
#
#   bin/rails shopline_orders:dedupe_pattern_a            # dry-run, prints the report, writes nothing
#   APPLY=1 bin/rails shopline_orders:dedupe_pattern_a     # deletes, backs up, records a SyncRun
#
# apply records a SyncRun(source: "shopline_orders_dedupe") for the whole
# attempt, including a genuine failure (e.g. a DB error) — not just the
# success/partial cases the service itself can report (see
# ShoplineOrdersDedupeRunner). Dry-run never writes to sync_runs (nothing
# happened to observe). meta only carries aggregate counts and
# per_product/skip-reason breakdowns — no email, name, or phone ever
# appears in it.

require Rails.root.join("lib/shopline_orders_dedupe_runner") if defined?(Rails)

namespace :shopline_orders do
  desc "Delete confirmed pattern-A duplicate order rows. Dry-run unless APPLY=1."
  task dedupe_pattern_a: :environment do
    if ENV["APPLY"] == "1"
      ShoplineOrdersDedupeRunner.apply
    else
      ShoplineOrdersDedupeRunner.dry_run
    end
  end
end
