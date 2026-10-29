# frozen_string_literal: true

# 訂單簡報／銷售日報／SEO 日報預覽：選日期在網頁上看整份報告（跟 LINE 發的同一份），自己複製文字、截表格貼到群組。
# 不經過 LINE，不用推播額度（小幫手免費方案額度用完時也能用）。
# 沒加進任何角色的 page_permissions，限 admin（同 line_bot_groups）。
class OrderBriefsController < ApplicationController
  def show
    @day = parse_date(params[:date]) || Date.current - 1
    return if params[:date].blank? # 第一次進來只顯示表單，按「產生簡報」才算（AI 重點要等約 1 分鐘）

    if params[:report] == "seo"
      # SEO 日報是平日早上跑、日期記當天，選「昨天」時要能拿到今天早上那份，所以抓選定日隔天以前最新一份
      @seo_report = SeoReport.where(status: %w[success partial], report_date: ..(@day + 1)).order(report_date: :desc).first
      @seo_text = Seo::LineDigest.new(@seo_report).message(ai: params[:ai] == "1") if @seo_report
      return
    end

    @report = OrderBrief::Report.new(@day)
    return if @report.empty?

    if params[:report] == "sales"
      @sales = SalesDaily::LineDigest.new(@day).sections
    else
      @highlights = OrderBrief::Highlights.call(@report) if params[:ai] == "1"
      @parts = OrderBrief::Sections.new(@report).parts
    end
  end

  private

  def parse_date(str)
    Date.parse(str.to_s)
  rescue Date::Error
    nil
  end
end
