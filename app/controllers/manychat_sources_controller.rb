# ManyChat 來源設定：穩定 ID、顯示名稱、內容類型、對應商品，以及互動紀錄裡的來源字串對應。
class ManychatSourcesController < ApplicationController
  before_action :load_source, only: [:edit, :update]

  def index
    @sources = ManychatSource.order(:account_key, :key)
    mapped = ManychatSource.index_by_raw_name
    @unmapped = ManychatInteraction.where.not(source: "").group(:source).order(Arel.sql("MAX(interacted_at) DESC"))
                                   .pluck(:source, Arel.sql("COUNT(*)"), Arel.sql("MAX(interacted_at)"))
                                   .reject { |name, _, _| mapped.key?(name) }
    @products = CrmProduct.where(key: @sources.flat_map(&:product_keys)).pluck(:key, :label).to_h
  end

  def new
    @source = ManychatSource.new(account_key: ManychatSubscriber.distinct.pick(:account_key), raw_names: [params[:raw_name]].compact,
                                 name: params[:raw_name])
  end

  def create
    @source = ManychatSource.new(source_params.merge(updated_by_user_id: current_user.id))
    if @source.save
      redirect_to manychat_sources_path, notice: "已新增來源 #{@source.key}"
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @source.update(source_params.except(:key).merge(updated_by_user_id: current_user.id))
      redirect_to manychat_sources_path, notice: "已更新來源 #{@source.key}"
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def load_source
    @source = ManychatSource.find(params[:id])
  end

  def source_params
    p = params.require(:manychat_source).permit(:key, :name, :account_key, :channel, :content_type, :content_ref, :campaign_key,
                                                :topic, :trigger_keyword, :flow_ns, :flow_version, :active, :notes,
                                                :raw_names_text, product_keys: [])
    p[:raw_names] = p.delete(:raw_names_text).to_s.split(/\r?\n/) if p.key?(:raw_names_text)
    p
  end
end
