class CreateCrmLivestreamOutreachTasks < ActiveRecord::Migration[7.1]
  def change
    # 「已確認的排程」需要落地保存，避免候選資料之後更新（例如新訂單進來、
    # matcher 重跑）讓每日任務內容漂移——候選 query 本身繼續即時計算，這張表
    # 只鎖住「已經排定要做的事」。
    #
    # identity_key 直接存在這張表上（不是只透過 crm_customer_product_cycle_id
    # 關聯查），是因為唯一性保護需要 (livestream_id, identity_key) 這組
    # DB 層級唯一索引，Postgres 唯一索引沒辦法跨表 join 出來的欄位做——
    # 這是一份快照，不是新的顧客識別來源，identity_key 的定義仍然完全沿用
    # CrmCustomerProductCycle 既有的欄位。
    create_table :crm_livestream_outreach_tasks do |t|
      t.bigint   :livestream_id,                  null: false
      t.bigint   :crm_customer_product_cycle_id,   null: false
      t.string   :identity_key,                    null: false, limit: 255
      t.bigint   :assigned_to_user_id,              null: false
      t.date     :scheduled_date,                   null: false
      t.string   :status,                           null: false, default: "pending"
      t.string   :candidate_reason,                 null: false, limit: 50
      # 顧客可能因多產品同時命中，這張表只建一筆顧客層級任務，但操作時仍要
      # 看得到所有命中產品與原因——存排程當下的快照（jsonb array of
      # {product_key:, reason:}），不即時重算，避免候選資料變動讓已存在的
      # 任務內容跟著漂移。
      t.jsonb    :hit_summary,                       null: false, default: []
      t.bigint   :created_by_user_id,                null: false
      t.datetime :completed_at

      t.timestamps
    end

    add_index :crm_livestream_outreach_tasks, [:livestream_id, :crm_customer_product_cycle_id],
              unique: true, name: "idx_outreach_tasks_on_livestream_cycle"
    add_index :crm_livestream_outreach_tasks, [:livestream_id, :identity_key],
              unique: true, name: "idx_outreach_tasks_on_livestream_identity"
    add_index :crm_livestream_outreach_tasks, [:assigned_to_user_id, :scheduled_date, :status],
              name: "idx_outreach_tasks_on_assignee_date_status"
    add_index :crm_livestream_outreach_tasks, :status

    add_foreign_key :crm_livestream_outreach_tasks, :livestreams
    add_foreign_key :crm_livestream_outreach_tasks, :crm_customer_product_cycles
    add_foreign_key :crm_livestream_outreach_tasks, :users, column: :assigned_to_user_id
    add_foreign_key :crm_livestream_outreach_tasks, :users, column: :created_by_user_id
  end
end
