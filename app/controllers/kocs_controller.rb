class KocsController < ApplicationController
  PER_PAGE = 10

  def index
    @sort = params[:sort]
    @kocs = @sort == "likes" ? Koc.order(Arel.sql("COALESCE(max_likes, 0) DESC")) : Koc.ordered_by_engagement
    @kocs = @kocs.where(status: params[:status]) if params[:status].present?
    @kocs = @kocs.where(has_paid_partnership: true) if params[:paid] == "1"

    @total_count = Koc.count
    @paid_count  = Koc.where(has_paid_partnership: true).count
    @status_counts = Koc.group(:status).count

    @page = [params[:page].to_i, 1].max
    @total_pages = [(@kocs.count.to_f / PER_PAGE).ceil, 1].max
    @page = @total_pages if @page > @total_pages
    @kocs = @kocs.offset((@page - 1) * PER_PAGE).limit(PER_PAGE)
  end

  def create
    @koc = Koc.new(koc_params)
    @koc.source = "手動新增"

    if @koc.save
      redirect_to kocs_path, notice: "已新增 #{@koc.ig_username}"
    else
      redirect_to kocs_path, alert: @koc.errors.full_messages.join("、")
    end
  end

  def update
    @koc = Koc.find(params[:id])
    @koc.update(koc_params)
    redirect_to kocs_path(status: params[:status]), notice: "已更新 #{@koc.ig_username}"
  end

  def destroy
    @koc = Koc.find(params[:id])
    @koc.destroy
    redirect_to kocs_path, notice: "已刪除 #{@koc.ig_username}"
  end

  private

  def koc_params
    params.require(:koc).permit(:ig_username, :ig_full_name, :alias, :email, :profile_url, :status, :notes)
  end
end
