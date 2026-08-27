# path: app/controllers/koc_search_controller.rb
# frozen_string_literal: true

# 「業配名單」分類群組底下有 6 個各品牌獨立的名單表（欄位結構完全相同），
# 用 email 找人時常常不知道對方被記在哪個品牌名單裡——這頁跨 6 張表一次查，
# 找到後導去該品牌原本的名單頁（帶 email 篩選），沿用該頁既有的權限控管與
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
    @email = params[:email].to_s.strip
    @results = @email.present? ? search(@email) : []
  end

  private

  def search(email)
    BRANDS.filter_map do |brand|
      records = brand[:model].where("email ILIKE ?", "%#{email}%").order(:ig_username)
      next if records.empty?

      { label: brand[:label], records: records, path: public_send(brand[:path_helper], email: email) }
    end
  end
end
