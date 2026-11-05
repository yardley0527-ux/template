# frozen_string_literal: true

# 報告中心：選日期按一下就跑常用報告。訂單簡報／銷售日報／SEO 日報／黑金卡回來了／生日名單跟 LINE 發的是同一份，
# 另外有區間報告（時段、客群、付款、產品）和沒回來名單。文字自己複製、表格截圖或複製貼到群組。
# 不經過 LINE，不用推播額度（小幫手免費方案額度用完時也能用）。
# 沒加進任何角色的 page_permissions，限 admin（同 line_bot_groups）。
class OrderBriefsController < ApplicationController
  RANGE_REPORTS = {
    "hours" => ReportCenter::Hours,
    "profile" => ReportCenter::Profile,
    "payments" => ReportCenter::Payments,
    "products" => ReportCenter::Products
  }.freeze
  RANGE_TITLES = { "hours" => "業績時段＋新舊客", "profile" => "客群輪廓", "payments" => "付款方式", "products" => "產品＋組合比例" }.freeze
  MAX_RANGE_DAYS = 400 # 區間報告會把訂單載進記憶體，避免選太長把 web 撐爆

  def show
    @day = parse_date(params[:date]) || Date.current - 1
    default = LineReportResendJob.default_days # 星期一預設五～日，其他天昨天
    @from = parse_date(params[:from]) || default.first
    @to = parse_date(params[:to]) || default.last
    @list_from = parse_date(params[:list_from]) || Date.current - 90
    @list_to = parse_date(params[:list_to]) || Date.current - 1
    @tab = tab_for(params[:report])
    return if params[:date].blank? && params[:report].blank? # 第一次進來只顯示表單，按按鈕才算（AI 重點要等約 1 分鐘）

    case params[:report]
    when "seo" then seo_report
    when "returns" then returns_report
    when "birthdays" then birthdays_report
    when "unrepurchased" then unrepurchased_report
    when *RANGE_REPORTS.keys then range_report
    else daily_report
    end
  end

  private

  # 跑完留在同一個分頁
  def tab_for(report)
    return "range" if RANGE_REPORTS.key?(report)

    report == "unrepurchased" ? "list" : "daily"
  end

  def daily_report
    @result_title = [params[:report] == "sales" ? "銷售日報" : "訂單簡報", md(@day)]
    @report = OrderBrief::Report.new(@day)
    return if @report.empty?

    if params[:report] == "sales"
      @sales = SalesDaily::LineDigest.new(@day).sections
      @sales_title = "#{md(@day)} 銷售日報"
    else
      @highlights = OrderBrief::Highlights.call(@report) if params[:ai] == "1"
      @parts = OrderBrief::Sections.new(@report).parts
    end
  end

  # SEO 日報是平日早上跑、日期記當天，選「昨天」時要能拿到今天早上那份，所以抓選定日隔天以前最新一份
  def seo_report
    @seo_report = SeoReport.where(status: %w[success partial], report_date: ..(@day + 1)).order(report_date: :desc).first
    @seo_text = Seo::LineDigest.new(@seo_report).message(ai: params[:ai] == "1") if @seo_report
    @result_title = ["SEO 日報", md(@seo_report&.report_date || @day)]
  end

  def returns_report
    days = returns_days
    @result_title = ["久未消費黑金卡回來了", range_label(days.first, days.last)]
    @sales = CrmReturns::LineDigest.new(days).sections
    @sales_title = "#{range_label(days.first, days.last)} 久未消費黑金卡回來了"
  end

  # 跟 LINE 一樣：星期一選昨天就看五到日（週末不匯入），其他日期看當天
  def returns_days
    default = LineReportResendJob.default_days
    @day == default.last ? default : @day..@day
  end

  # 生日名單以週為單位：選「昨天」要拿到今天這週（星期一的昨天是上一週）
  def birthdays_report
    week = (@day + 1).beginning_of_week
    @result_title = ["生日名單", range_label(week, week + 6)]
    @sales = CrmBirthdays::LineDigest.new(week).sections
    @sales_title = "#{range_label(week, week + 6)} 生日名單"
  end

  def range_report
    return unless valid_range?(@from, @to)

    @result_title = [RANGE_TITLES.fetch(params[:report]), [range_label(@from, @to), params[:product].to_s.strip.presence].compact.join("｜只看 ")]
    data = ReportCenter::Orders.new(@from..@to, product: params[:product])
    if data.empty?
      @error = "#{range_label(@from, @to)} 沒有符合的已付款訂單（可能還沒匯入）"
    else
      @parts = RANGE_REPORTS.fetch(params[:report]).new(data).parts
    end
  end

  def unrepurchased_report
    return unless valid_range?(@list_from, @list_to)
    return @error = "請輸入產品關鍵字，例如 PDRN" if params[:product_list].to_s.strip.blank?

    @result_title = ["買了沒回來名單", "#{params[:product_list].strip}｜#{range_label(@list_from, @list_to)}"]
    @parts = ReportCenter::Unrepurchased.new(product: params[:product_list], range: @list_from..@list_to,
                                             audience: params[:audience], min_amount: params[:min_amount],
                                             exclude_preorder: params[:exclude_preorder] == "1",
                                             skip_days: params[:skip_days]).parts
  end

  def valid_range?(from, to)
    @error = "結束日期不能早於開始日期" if from > to
    @error = "一次最多跑 #{MAX_RANGE_DAYS} 天" if (to - from).to_i >= MAX_RANGE_DAYS
    @error.nil?
  end

  def range_label(from, to) = from == to ? md(from) : "#{md(from)}–#{md(to)}"
  def md(date) = "#{date.month}/#{date.day}"

  def parse_date(str)
    Date.parse(str.to_s)
  rescue Date::Error
    nil
  end
end
