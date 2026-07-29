class LivestreamsController < ApplicationController
  before_action :set_livestream, only: [:edit, :update, :destroy]

  def index
    @years  = Livestream.pluck(:date).map(&:year).uniq.sort.reverse
    @selected_year    = params[:year].presence&.to_i
    @selected_month   = params[:month].presence&.to_i
    @selected_product = params[:product].presence
    @product_options  = CrmProduct.for_analysis.order(:label).pluck(:key, :label)
    @product_labels   = CrmProduct.pluck(:key, :label).to_h

    # 列表只讀 livestreams 自己的欄位（含 PR2 寫入的統計快取），不 include
    # 商品/贈品/圖片關聯、不逐場執行 LivestreamAttribution——避免 N+1。
    @livestreams = filtered_scope
  end

  def show
    @livestream = Livestream.includes(:livestream_images, :livestream_products, :livestream_gifts)
                            .find(params[:id])
    @attribution = LivestreamAttribution.new(@livestream)
    # 只有「每日拆解」是即時算（livestreams 沒有存 day-by-day 欄位）；
    # KPI／卡別/歷史登記一律讀 PR2 寫入的快取欄位，不在這裡重算或寫入。
    @daily_breakdown = Rails.cache.fetch(daily_breakdown_cache_key, expires_in: 15.minutes) do
      @attribution.daily_breakdown
    end
    @unmapped_products = LivestreamReconciliationLookup.unmapped_products_for(@livestream.date)
    @product_labels = CrmProduct.pluck(:key, :label).to_h
  end

  def new
    @livestream = Livestream.new
    @product_options = CrmProduct.for_analysis.order(:label).pluck(:key, :label)
  end

  def create
    @livestream = Livestream.new(livestream_params)
    if @livestream.save
      redirect_to livestreams_path, notice: "直播已建立"
    else
      @product_options = CrmProduct.for_analysis.order(:label).pluck(:key, :label)
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @product_options = CrmProduct.for_analysis.order(:label).pluck(:key, :label)
  end

  def update
    if @livestream.update(livestream_params)
      redirect_to livestreams_path, notice: "直播已更新"
    else
      @product_options = CrmProduct.for_analysis.order(:label).pluck(:key, :label)
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @livestream.destroy
    redirect_to livestreams_path, notice: "直播已刪除"
  end

  private

  def set_livestream
    @livestream = Livestream.find(params[:id])
  end

  def filtered_scope
    scope = Livestream.all
    if @selected_year
      start_date = Date.new(@selected_year, @selected_month || 1, 1)
      end_date   = @selected_month ? start_date.end_of_month : Date.new(@selected_year, 12, 31)
      scope = scope.where(date: start_date..end_date)
    elsif @selected_month
      scope = scope.where("EXTRACT(MONTH FROM date) = ?", @selected_month)
    end
    # GIN 相容的 array contains 查詢（同 PR1 設計文件記錄的寫法）。
    scope = scope.where("product_keys @> ARRAY[?]::varchar[]", @selected_product) if @selected_product

    scope
  end

  # 含 date：id 目前雖與 date 一對一，但 LivestreamBackfill 曾經、未來也可能
  # 再修正某場的日期（PR1 的 11/22→11/21 那類訂正）——那次寫入若剛好沒動到
  # stats_refreshed_at，少了 date 這個 cache key 分量就會撈到用「舊日期」算出
  # 的 daily_breakdown。有 date 落在 key 裡，日期一變就自然是新 cache key。
  def daily_breakdown_cache_key
    "livestream_daily_breakdown/#{@livestream.id}/#{@livestream.date.iso8601}/#{@livestream.window_days}/#{@livestream.stats_refreshed_at&.to_i || 0}"
  end

  def livestream_params
    params.require(:livestream).permit(:date, :title, :notes, product_keys: [])
  end
end
