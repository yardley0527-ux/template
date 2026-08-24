# path: app/controllers/canceled_order_candidates_controller.rb
# frozen_string_literal: true

# Shopline 匯出檔從不標記「已取消」— 一張已付款的訂單被取消後，只是從下一次
# 匯出裡消失。Importing::CanceledOrderCandidates 用「這個 年/月 還在 DB 裡是
# 已付款，但沒被最新一次匯入碰到」當作最佳判斷依據。這頁把候選名單攤在畫面上
# 讓人工確認，purge 動作才是真的刪除（僅 admin 可做，且會重刷分析快取）。
class CanceledOrderCandidatesController < ApplicationController
  def index
    @year_months = ShoplineOrder.where(payment_status: "已付款")
      .where.not(source_year: nil)
      .where.not(source_month: nil)
      .distinct
      .order(source_year: :desc, source_month: :desc)
      .pluck(:source_year, :source_month)

    @year  = params[:year].presence&.to_i  || @year_months.first&.first
    @month = params[:month].presence&.to_i || @year_months.first&.last

    @candidates = if @year && @month
      Importing::CanceledOrderCandidates.call(year: @year, month: @month).to_a
    else
      []
    end
  end

  def purge
    return head :forbidden unless current_user.admin?

    year  = params[:year].to_i
    month = params[:month].to_i

    candidates = Importing::CanceledOrderCandidates.call(year: year, month: month).to_a

    if candidates.empty?
      redirect_to canceled_order_candidates_path(year: year, month: month), alert: "目前沒有候選名單可刪除"
      return
    end

    deleted = ShoplineOrder.where(id: candidates.map(&:id)).delete_all

    RefreshCustomerPurchaseSummariesJob.perform_later
    RefreshCustomerSeriesLoyaltiesJob.perform_later

    redirect_to canceled_order_candidates_path(year: year, month: month),
      notice: "已刪除 #{deleted} 筆訂單，分析快取已排入背景重新整理"
  end
end
