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
        desc: "長期定價版：全歷史場次定價階梯拆解＋跨產品預購比較，8/12更新至預購開賣後2天累計（薑黃買氣約番茄同期2.7倍差距，仍在觀察）",
      },
    ],
    "膠原蛋白" => [
      {
        title: "膠原蛋白回購活動報表・8/21場",
        date: Date.new(2026, 8, 21),
        type: :post,
        url: "https://claude.ai/code/artifact/8055f366-2bee-49f5-954c-2436181d940d",
        desc: "買家名單版：歷史場次比較／新客大單／鐵粉流失／快要吃完／買更多／買很少，卡別分佈＋交叉對照8/21傳訊名單(list_id=12)",
      },
      {
        title: "膠原直播決策報告：這次快在哪、下一步怎麼做",
        date: Date.new(2026, 8, 21),
        type: :post,
        url: "https://claude.ai/code/artifact/e1de626a-2740-4d47-bfec-1b3b7f4ed6b8",
        desc: "老闆決策版：跟去年同日YoY比較／首3天排名／定價級距分析／下貨方案／執行建議",
      },
      {
        title: "膠原直播前報告：8/21 場前的診斷與建議",
        date: Date.new(2026, 8, 21),
        type: :pre,
        url: "https://claude.ai/code/artifact/2e6258b0-466d-450c-a4ba-cf8e14eada06",
        desc: "直播前診斷：買氣走勢、92天缺貨、現行定價階梯與8/21建議定價（6盒送1／10盒送2）、行動建議",
      },
      {
        title: "膠原定價策略檢討：折扣階梯止步在哪",
        date: Date.new(2026, 8, 12),
        type: :pre,
        url: "https://claude.ai/code/artifact/b4d26203-baca-4ed4-b9ef-1da26c216ec2",
        desc: "6場歷史走勢比較＋定價階梯拆解：現行1~4盒折扣已達-27%但止步4盒，附8/21建議定價",
      },
    ],
    "魚油" => [
      {
        title: "魚油直播檢討：9/4 場前的診斷與建議",
        date: Date.new(2026, 9, 4),
        type: :pre,
        url: "https://claude.ai/code/artifact/ec872847-dc76-405f-8da3-333649e2f5d3",
        desc: "直播前診斷：15個月買氣走勢（4月起近乎歸零，回補後仍未回升）、4場歷史場次比較（6/20、11/21皆為獨立主打，客單價/黑卡/24h佔比）、逐場買家與新客趨勢、4場逐時賣貨速度、最終定價（1/3/6+1/10+2盒）、進貨2000盒預估營收$327萬、6/20首場29天完整銷售時間線＋卡別分布（黑卡佔箱量29.8%但買家僅14.5%）",
      },
    ],
  }.freeze

  def index
    @reports_by_product = REPORTS
  end
end
