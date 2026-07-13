# frozen_string_literal: true

require "test_helper"

class AnnualCalendarSyncTest < ActiveSupport::TestCase
  class NoSheetSync < AnnualCalendarSync
    private

    def find_year_sheet(_year)
      nil
    end
  end

  class ExplodingSync < AnnualCalendarSync
    private

    def find_year_sheet(_year)
      raise OpenURI::HTTPError.new("403 Forbidden", StringIO.new)
    end
  end

  test "records failed SyncRun when the year tab is missing" do
    result = NoSheetSync.new.call

    assert result[:error].present?
    run = SyncRun.latest_for("annual_calendar")
    assert_equal "failed", run.status
    assert_includes run.error_messages.first, "總表"
  end

  test "download errors are captured, not raised" do
    result = nil
    assert_nothing_raised { result = ExplodingSync.new.call }

    assert_includes result[:error], "OpenURI::HTTPError"
    assert_equal "failed", SyncRun.latest_for("annual_calendar").status
  end
end
