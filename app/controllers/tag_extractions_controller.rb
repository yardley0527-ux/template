# path: app/controllers/tag_extractions_controller.rb
# frozen_string_literal: true

# 只買一次加 Tag 名單：每次抓取接著上一批的 range_end 繼續往後抓，
# 抓出來的客人是要在 Omnichat 上加 tag 的名單。
class TagExtractionsController < ApplicationController
  def index
    @runs = TagExtractionRun.order(range_start: :desc, id: :desc).to_a
    @next_range_start = (TagExtractionRun.maximum(:range_end) + 1.day) if TagExtractionRun.any?
    @next_range_start ||= Date.current
    @next_range_end = Date.current
  end

  def create
    range_start = (TagExtractionRun.maximum(:range_end) + 1.day if TagExtractionRun.any?) || Date.current
    range_end = Date.current

    if range_start > range_end
      redirect_to tag_extractions_path, alert: "沒有新的區間可以抓（上一批已經抓到今天了）"
      return
    end

    run = TagExtractionService.call(range_start: range_start, range_end: range_end)
    redirect_to tag_extractions_path, notice: "抓到 #{run.range_start} ~ #{run.range_end}：共 #{run.customer_count} 人"
  end

  def export
    run = TagExtractionRun.find(params[:id])

    require "csv"

    csv = CSV.generate(encoding: "UTF-8") do |rows|
      rows << ["姓名", "購買產品", "LINE ID", "Email", "購買年月"]
      run.recipients.order(:category, :purchase_month).each do |r|
        rows << [r.full_name, r.product_name.presence || r.category, r.line_id, r.email, r.purchase_month]
      end
    end

    send_data "\xEF\xBB\xBF" + csv,
              filename: "只購買一次名單_#{run.range_start}_#{run.range_end}.csv",
              type: "text/csv; charset=utf-8"
  end
end
