class AddSecondFamiliesToCustomerCohortStats < ActiveRecord::Migration[7.1]
  def change
    # 首購之後「第二筆訂單」買了哪些產品類別（含同產品，不含其他）
    add_column :customer_cohort_stats, :second_families, :string, array: true, default: [], null: false
  end
end
