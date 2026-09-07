# path: app/controllers/koc_search_controller.rb
# frozen_string_literal: true

# 「業配名單」分類群組底下有 6 個各品牌獨立的名單表（欄位結構完全相同），
# 用 IG 帳號找人時常常不知道對方被記在哪個品牌名單裡——這頁跨 6 張表一次查，
# 找到後導去該品牌原本的名單頁（帶 IG 帳號篩選），沿用該頁既有的權限控管與
# 就地編輯表單，不重造一套跨品牌的編輯介面。
class KocSearchController < ApplicationController
  BRANDS = [
    { model: Koc,             label: "Hiff",       path_helper: :kocs_path },
    { model: ReloveKoc,       label: "Relove",     path_helper: :relove_kocs_path },
    { model: BodyGoalsKoc,    label: "Body Goals", path_helper: :body_goals_kocs_path },
    { model: BetterbioKoc,    label: "好好生醫",   path_helper: :betterbio_kocs_path },
    { model: DianbopopoKoc,   label: "Dianbopopo", path_helper: :dianbopopo_kocs_path },
    { model: AkimiaKoc,       label: "微電流面膜", path_helper: :akimia_kocs_path }
  ].freeze

  def index
    @query = params[:query].to_s.strip.delete_prefix("@")
    @results = @query.present? ? search(@query) : []
  end

  private

  # 目的頁（各品牌名單頁）只支援用 ig_username 篩選，沒有 email 篩選。
  # 如果這次搜尋字串本身就能比對到 ig_username，就沿用原本行為——直接把搜尋字串
  # 帶過去（目的頁自己也是用同樣的 ILIKE 部分比對，可以一次篩出好幾筆同時符合的人）。
  # 但如果是「只比對到 email、比對不到 ig_username」的情況（例如直接搜 email），
  # 搜尋字串本身沒辦法拿去給目的頁篩選，改用「這筆記錄自己的」ig_username
  # （presence + uniqueness 驗證保證存在且能精準篩到那一筆）。
  def search(query)
    BRANDS.filter_map do |brand|
      records = brand[:model]
                  .where("ig_username ILIKE :q OR email ILIKE :q", q: "%#{query}%")
                  .order(:ig_username)
      next if records.empty?

      matched_by_ig = records.any? { |r| r.ig_username.to_s.downcase.include?(query.downcase) }
      filter_value = matched_by_ig ? query : records.first.ig_username

      { label: brand[:label], records: records, path: public_send(brand[:path_helper], ig_username: filter_value) }
    end
  end
end
