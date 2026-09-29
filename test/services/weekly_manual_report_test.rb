# frozen_string_literal: true

require "test_helper"

class WeeklyManualReportTest < ActiveSupport::TestCase
  test "loads the 2026-09-21 report" do
    report = WeeklyManualReport.for(Date.new(2026, 9, 21))

    assert report.present?
    assert_includes report[:title], "9 月第 4 週"
    assert report[:sections].any?
  end

  test "returns nil for a week without a report" do
    assert_nil WeeklyManualReport.for(Date.new(2026, 6, 15))
  end

  test "every table row has as many cells as headers" do
    WeeklyManualReport.all.each do |week_start, _title|
      WeeklyManualReport.for(week_start)[:sections].each do |section|
        Array(section[:blocks]).each do |block|
          next unless block[:table]

          width = block[:table][:headers].size
          block[:table][:rows].each do |row|
            assert_equal width, row.size, "#{week_start} #{section[:heading]}: #{row.inspect}"
          end
        end
      end
    end
  end

  test "all lists the available reports newest first" do
    assert_includes WeeklyManualReport.all.map(&:first), Date.new(2026, 9, 21)
  end
end
