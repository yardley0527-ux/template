class LiveAdTestsController < ApplicationController
  before_action :set_live_ad_test, only: [:edit, :update, :destroy]

  def index
    @selected_platform = params[:platform].presence
    scope = LiveAdTest.all
    scope = scope.where(platform: @selected_platform) if @selected_platform
    @live_ad_tests = scope

    @counts = {
      all: LiveAdTest.count,
      "IG" => LiveAdTest.where(platform: "IG").count,
      "蝦皮" => LiveAdTest.where(platform: "蝦皮").count,
    }
  end

  def new
    @live_ad_test = LiveAdTest.new
  end

  def create
    @live_ad_test = LiveAdTest.new(live_ad_test_params)
    if @live_ad_test.save
      redirect_to live_ad_tests_path, notice: "已新增"
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @live_ad_test.update(live_ad_test_params)
      redirect_to live_ad_tests_path, notice: "已更新"
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @live_ad_test.destroy
    redirect_to live_ad_tests_path, notice: "已刪除"
  end

  private

  def set_live_ad_test
    @live_ad_test = LiveAdTest.find(params[:id])
  end

  def live_ad_test_params
    params.require(:live_ad_test).permit(
      :date, :platform, :product, :link_keyword, :start_time, :end_time,
      :ran_ads, :ad_approved_time, :ad_spend,
      :viewers_entry, :viewers_peak, :viewers_end,
      :orders, :revenue, :notes
    )
  end
end
