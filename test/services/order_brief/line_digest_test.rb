# frozen_string_literal: true

require "test_helper"

module OrderBrief
  class LineDigestTest < ActiveSupport::TestCase
    class FakeLine
      attr_reader :sent

      def initialize = @sent = []
      def push_messages(to, messages) = @sent << [to, messages]
    end

    DAY = Date.new(2026, 10, 22)

    setup do
      @old_token = ENV["LINE_REPORT_CHANNEL_ACCESS_TOKEN"]
      @old_ai = ENV.delete("ANTHROPIC_API_KEY") # 不打真的 AI：沒有重點時照樣發
      ENV["LINE_REPORT_CHANNEL_ACCESS_TOKEN"] = "token"
      LineBotGroup.create!(group_id: "Cstrategy", name: "苼莛國際-策略部", subscriptions: ["order_brief"])
      LineBotGroup.create!(group_id: "Cseo", subscriptions: ["seo_daily"])

      ShoplineCustomer.create!(email: "amy@example.com", full_name: "Amy", membership_level: "黑卡", instagram_account: "amy_ig")
      ShoplineCustomer.create!(email: "amy.alt@example.com", full_name: "Amy 分身", instagram_account: "AMY_IG")
      ShoplineCustomer.create!(email: "bob@example.com", full_name: "Bob", membership_level: "銀卡")
      ShoplineCustomer.create!(email: "new@example.com", full_name: "Newbie", instagram_account: "無")
      ShoplineCustomer.create!(email: "x@example.com", full_name: "Xin", instagram_account: "無")

      # Amy：用分身 email 買過 PDRN3，今天回購 PDRN6＋全能
      order("#A1", "amy.alt@example.com", Date.new(2026, 9, 20), [["PDRN3", 1]], 9000)
      order("#A2", "amy@example.com", DAY, [["PDRN6", 1], ["全能1", 2]], 20000)
      # Bob：以前只買過全能，今天第一次買 PDRN；薑黃成對行只算一次
      order("#B1", "bob@example.com", Date.new(2026, 5, 1), [["全能3", 1]], 5000)
      order("#B2", "bob@example.com", DAY, [["預購-PDRN3", 1], ["薑黃3", 1], ["薑黃3送1", 1]], 12000)
      # 新客
      order("#N1", "new@example.com", DAY, [["益生菌2", 1]], 2000)
      # 跟新客同一個「無」IG 不能被當成同一人
      order("#X1", "x@example.com", Date.new(2026, 1, 1), [["魚油1", 1]], 800)
    end

    teardown do
      ENV["LINE_REPORT_CHANNEL_ACCESS_TOKEN"] = @old_token
      ENV["ANTHROPIC_API_KEY"] = @old_ai if @old_ai
    end

    # minitest 6 沒有 stub，暫時換掉 class method，跑完換回來
    def replace(klass, name, impl)
      original = klass.method(name)
      klass.define_singleton_method(name, &impl)
      yield
    ensure
      klass.define_singleton_method(name, original)
    end

    def order(number, email, date, items, total)
      items.each do |name, qty|
        ShoplineOrder.create!(order_number: number, email: email, product_name: name, quantity: qty,
                              total_amount: total, payment_status: "已付款", order_date: Time.utc(date.year, date.month, date.day))
      end
    end

    test "簡報口徑：IG 分身算同一人、新客、卡別、瓶數" do
      r = Report.new(DAY)
      s = r.summary
      assert_equal [3, 3, 34_000], s.values_at(:people, :orders, :revenue)
      assert_equal [1, 2000, 6], s.values_at(:new_people, :new_revenue, :new_share)

      black = r.level_stats.find { |l| l[:level] == "黑卡" }
      assert_equal [1, 20_000], black.values_at(:people, :amount)
      assert_equal 1, r.level_stats.find { |l| l[:level] == "一般會員" }[:new_people]

      pdrn = r.product_stats.find { |p| p[:series] == "PDRN" }
      assert_equal [2, 9, 3], pdrn.values_at(:people, :paid, :pre)
      turmeric = r.product_stats.find { |p| p[:series] == "薑黃" }
      assert_equal [3, 1], turmeric.values_at(:paid, :gift)

      f = r.focus("PDRN")
      assert_equal [2, 1, 1, 0], [f[:buyers], f[:repeat].size, f[:first].size, f[:fresh].size]
      amy = f[:repeat].first
      assert_equal ["Amy", "黑", 32], amy.values_at(:name, :level, :gap)
      assert_equal "第 2 次買 PDRN，從 3 瓶升到 6 瓶，加購全能", amy[:note]
      bob = f[:first].first
      assert_equal ["Bob", 174, "全能3"], bob.values_at(:name, :gap, :last_items)

      assert_equal ["Bob"], r.long_gap.map { |e| e[:name] }
      assert_equal ["Amy"], r.back_within.map { |e| e[:name] }
      assert_equal ["Newbie"], r.other_new.map { |e| e[:name] }
    end

    test "總覽文字照使用者的格式" do
      text = Sections.new(Report.new(DAY)).overview_text
      assert_includes text, "10/22 全天共 3 人下單、3 張單，營收 $34,000"
      assert_includes text, "新客 1 人、1 張單，營收 $2,000，占 6%"
      assert_includes text, "依卡別分：\n黑卡 1 人，$20,000\n金卡 0 人"
      assert_includes text, "一般會員 1 人（含新客 1 人），$2,000"
      assert_includes text, "PDRN 2 人，付費 9 瓶（預購 3 瓶）"
      assert_includes text, "薑黃 1 人，付費 3 瓶，另送 1 瓶"
    end

    test "段落順序：總覽 → PDRN 表 → 全能表 → 其他新客 → 很久沒回來表" do
      parts = Sections.new(Report.new(DAY)).parts
      assert_equal [:text, :image, :image, :text, :image], parts.map(&:first)
      assert_equal "PDRN（2 人：回購 1、舊客第一次買 1、新客 0）", parts[1][2]
      assert_includes parts[3][1], "其他新客（1 人）：Newbie（益生菌2，$2,000）"

      pdrn = parts[1][3]
      table = pdrn.find { |b| b[0] == :table }
      assert_equal ["客人", "卡別", "今天買", "整單", "上次買 PDRN", "隔幾天", "備註"], table[1]
      assert_equal ["Amy", "黑", "PDRN6、全能1×2", "$20,000", "9/20（PDRN3）", "32 天", "第 2 次買 PDRN，從 3 瓶升到 6 瓶，加購全能"], table[2].first
    end

    test "表格畫成 PDF，中文字型沒有的字拿掉" do
      pdf = TableImage.new([[:heading, "回購 PDRN（1 人）", "依「多久沒回來」排序"],
                            [:table, %w[客人 隔幾天], [["🐣倫倫🐣", "7 天"]], [1]],
                            [:text, "新客買 PDRN（0 人）"]]).render
      assert pdf.start_with?("%PDF")
    end

    test "訊息順序：重點、總覽、表格圖片；圖片做不出來改發說明，其他照發" do
      report = Report.new(DAY)
      highlights = [{ "title" => "PDRN 回購都升級", "details" => ["Amy 從 3 瓶升到 6 瓶"] }]
      msgs = LineDigest.new(DAY, line: FakeLine.new).messages(report, highlights)
      assert msgs.all? { |m| m[:type] == "text" } # 測試環境沒有 Cloudinary，表格改發說明
      assert msgs.all? { |m| LineBot::Client.visual_lines(m[:text]) <= LineBot::Client::READABLE_LINES }, "每則都要能直接看完"
      assert_equal "📝 10/22 今天的重點\n\n1. PDRN 回購都升級\n- Amy 從 3 瓶升到 6 瓶", msgs[0][:text]
      assert msgs[1][:text].start_with?("📦 10/22 訂單簡報")
      assert msgs.any? { |m| m[:text].include?("表格圖片產生失敗") }

      fake_upload = ->(pdf, **) { { type: "image", originalContentUrl: "https://x/#{pdf.bytesize}.png", previewImageUrl: "https://x/p.jpg" } }
      replace(ImageHost, :configured?, -> { true }) do
        replace(ImageHost, :upload, fake_upload) do
          types = LineDigest.new(DAY, line: FakeLine.new).messages(report, nil).map { |m| m[:type] }
          assert_equal %w[image image text image], types.drop_while { |t| t == "text" }
        end
      end
    end

    test "長訊息切成每則都能直接看完，不會被折成 See more" do
      long = ["📝 重點", *Array.new(7) { |i| "#{i + 1}. 結論#{i}\n- " + ("補充" * 30) + "\n- " + ("說明" * 20) }].join("\n\n")
      parts = LineBot::Client.split_readable(long)
      assert parts.size > 1
      assert parts.all? { |p| LineBot::Client.visual_lines(p) <= LineBot::Client::READABLE_LINES }
      assert_equal long.gsub(/\n+/, ""), parts.join.gsub(/\n+/, ""), "內容不能少"
    end

    test "超過 5 則分批推，順序不變" do
      line = FakeLine.new
      highlights = [{ "title" => "重點", "details" => [] }]
      replace(Highlights, :call, ->(_) { highlights }) { LineDigest.new(DAY, line: line).call }
      assert line.sent.size > 1
      assert line.sent.all? { |_, batch| batch.size <= 5 }
      assert_equal "📝 10/22 今天的重點\n\n1. 重點", line.sent.first[1].first[:text]
    end

    test "只發給有訂閱的群組，同一天只發一次" do
      line = FakeLine.new
      assert_equal 1, LineDigest.new(DAY, line: line).call
      assert_equal ["Cstrategy"], line.sent.map(&:first).uniq
      assert_equal 0, LineDigest.new(DAY, line: line).call
      assert_equal 1, LineDigest.new(DAY, line: line).call(force: true)
      assert_equal 1, LineDigestDelivery.where(report_date: DAY).count
    end

    test "當天還沒有訂單（還沒匯入）不發也不記錄" do
      assert_equal 0, LineDigest.new(DAY + 1, line: FakeLine.new).call
      assert_equal 0, LineDigestDelivery.count
    end

    test "推播失敗時拿掉紀錄，下次匯入還能再發" do
      broken = Object.new
      def broken.push_messages(*) = raise(LineBot::Client::Error, "LINE 500")
      assert_raises(LineBot::Client::Error) { LineDigest.new(DAY, line: broken).call }
      assert_equal 0, LineDigestDelivery.count
    end
  end
end
