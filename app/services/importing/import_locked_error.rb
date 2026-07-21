# frozen_string_literal: true

module Importing
  # Raised when the shared ShoplineOrdersMaintenanceLock is held by a rehash
  # or dedupe run — the import does not proceed at all (no ImportRun is
  # created) rather than risk racing on the same rows those maintenance
  # operations are rewriting.
  class ImportLockedError < StandardError; end
end
