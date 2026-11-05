# Chloe 的歷史回覆本身就是核准過的答案，不用再逐筆核准。
class ApproveInstagramReplyKnowledge < ActiveRecord::Migration[7.1]
  def up
    execute "UPDATE reply_knowledge_items SET status = 'approved', updated_at = NOW() WHERE source = 'instagram' AND status = 'pending'"
  end

  def down
    execute "UPDATE reply_knowledge_items SET status = 'pending', updated_at = NOW() WHERE source = 'instagram' AND status = 'approved' AND reviewed_at IS NULL"
  end
end
