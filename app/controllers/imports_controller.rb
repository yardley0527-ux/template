# path: app/controllers/imports_controller.rb
#
# 讓「已付款訂單」「顧客名單」匯入可以直接在網頁上上傳檔案觸發，取代原本
# 手動跑 rake task／打 Render Jobs API 的流程。實際匯入邏輯完全沿用既有
# Importing::PaidOrdersWorkbookImporter / CustomersReportImporter，這裡只
# 負責把上傳檔案落地成路徑，交給對應的 ActiveJob 非同步處理。
#
# 沒有另外寫權限檢查：這個 controller 沒被加進任何角色的 page_permissions，
# ApplicationController#authorize_page! 預設就只放行 admin，符合「限 admin
# 帳號使用」的需求（同 users_path 等工具頁的作法）。
class ImportsController < ApplicationController
  IMPORTS_DIR = Rails.root.join("tmp", "imports")
  ALLOWED_EXTENSIONS = %w[.xlsx .xls .csv].freeze

  def index
    @import_runs = ImportRun.order(created_at: :desc).limit(30)
  end

  # 前端輪詢用：匯入在背景 job 執行，這支給頁面上的 JS 定期讀取最新狀態，
  # 一完成就跳提示、不用手動重新整理。
  def status
    runs = ImportRun.order(created_at: :desc).limit(30)
    render json: runs.map { |run|
      {
        id: run.id,
        kind_label: run.kind_label,
        file_name: run.file_name,
        started_at: run.started_at,
        finished_at: run.finished_at,
        processed_rows: run.processed_rows,
        upserted_rows: run.upserted_rows,
        skipped_rows: run.skipped_rows,
        error_rows: run.error_rows,
        error_messages: run.error_messages.first(5)
      }
    }
  end

  def create
    uploaded = params[:file]
    if uploaded.blank?
      return redirect_to imports_path, alert: "請選擇要上傳的檔案"
    end

    ext = File.extname(uploaded.original_filename.to_s).downcase
    unless ALLOWED_EXTENSIONS.include?(ext)
      return redirect_to imports_path, alert: "檔案格式需為 .xlsx / .xls / .csv"
    end

    dest_path = save_upload(uploaded, ext)

    case params[:kind]
    when "paid_orders"
      year = params[:source_year].to_s.to_i
      month = params[:source_month].presence&.to_i

      if year <= 0
        File.delete(dest_path)
        return redirect_to imports_path, alert: "請填寫正確的年份"
      end
      if month && (month < 1 || month > 12)
        File.delete(dest_path)
        return redirect_to imports_path, alert: "月份需為 1–12"
      end

      ImportPaidOrdersJob.perform_later(dest_path.to_s, source_year: year, source_month: month)
      redirect_to imports_path, notice: "已付款訂單匯入已加入排程，處理需要一些時間，請稍後重新整理查看結果"
    when "customers_report"
      ImportCustomersJob.perform_later(dest_path.to_s)
      redirect_to imports_path, notice: "顧客名單匯入已加入排程，處理需要一些時間，請稍後重新整理查看結果"
    else
      File.delete(dest_path)
      redirect_to imports_path, alert: "未知的匯入類型"
    end
  end

  private

  def save_upload(uploaded, ext)
    FileUtils.mkdir_p(IMPORTS_DIR)
    dest = IMPORTS_DIR.join("#{SecureRandom.hex(8)}#{ext}")
    File.open(dest, "wb") { |f| IO.copy_stream(uploaded, f) }
    dest
  end
end
