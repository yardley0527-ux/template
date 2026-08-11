# 分產品的直播檢討報告清單（Claude Artifact 連結），資料寫死在這裡，
# 每次新增一場報告時手動加進 REPORTS。
class LivestreamReportsController < ApplicationController
  REPORTS = {
    "薑黃" => [
      {
        title: "薑黃回購活動報表・8/7場",
        date: Date.new(2026, 8, 7),
        type: :post,
        url: "https://claude.ai/code/artifact/bebcd095-27b8-4445-98de-c78666ff568d",
        desc: "買家名單版：新客大單／鐵粉流失／快要吃完／買更多／買很少",
      },
      {
        title: "薑黃直播決策報告：這次快在哪、下一步怎麼做",
        date: Date.new(2026, 8, 7),
        type: :post,
        url: "https://claude.ai/code/artifact/c40755c1-a86b-4e92-a567-110ce46e99af",
        desc: "老闆決策版：速度排名／定價分析／下貨方案／執行建議",
      },
      {
        title: "薑黃定價與下貨策略檢討",
        date: Date.new(2026, 8, 7),
        type: :post,
        url: "https://claude.ai/code/artifact/f4082dda-75c0-4787-9ada-0835b1e37eb5",
        desc: "長期定價版：全歷史場次定價階梯拆解＋跨產品預購比較",
      },
    ],
    "膠原蛋白" => [
      {
        title: "膠原直播檢討：8/21 場前的診斷與建議",
        date: Date.new(2026, 8, 21),
        type: :pre,
        url: "https://claude.ai/code/artifact/2e6258b0-466d-450c-a4ba-cf8e14eada06",
        desc: "直播前診斷：套用薑黃報告框架反查膠原買氣走勢與斷貨缺口",
      },
      {
        title: "膠原定價策略檢討：折扣階梯止步在哪",
        date: Date.new(2026, 8, 12),
        type: :pre,
        url: "https://claude.ai/code/artifact/b4d26203-baca-4ed4-b9ef-1da26c216ec2",
        desc: "6場歷史走勢比較＋定價階梯拆解：現行1~4盒折扣已達-27%但止步4盒，附8/21建議定價",
      },
    ],
  }.freeze

  def index
    @reports_by_product = REPORTS
  end
end
