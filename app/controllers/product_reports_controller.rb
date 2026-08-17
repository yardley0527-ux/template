# 分產品的「今年 vs 去年、誰流失了」檢討報告清單（Claude Artifact 連結），
# 資料寫死在這裡，每次新增一個產品的報告時手動加進 REPORTS。
# 公司產品全清單見 CrmProduct；優先順序：膠原、薑黃、全能，其餘陸續補上。
class ProductReportsController < ApplicationController
  REPORTS = {
    "膠原蛋白" => [
      {
        title: "膠原今年 vs 去年：誰沒有回來買",
        date: Date.new(2026, 8, 17),
        url: "https://claude.ai/code/artifact/ada2e4f0-4951-4207-9633-c3595d07f76d",
        desc: "排除92天缺貨期的公平同期比較，仍下滑76%；拆解卡別回頭率＋流失兩種樣態＋直播曝光度",
      },
    ],
    "薑黃" => [
      {
        title: "薑黃今年 vs 去年：誰沒有回來買",
        date: Date.new(2026, 8, 17),
        url: "https://claude.ai/code/artifact/ada23715-2bc0-4587-812f-8e64e6ff8462",
        desc: "買家流失73.6%但營收反增17.3%（大宗送贈拉高客單價）；仍持續有專屬場次，跟代謝錠/膠原的曝光度問題不同",
      },
    ],
    "全能" => [
      {
        title: "全能今年 vs 去年：誰沒有回來買",
        date: Date.new(2026, 8, 17),
        url: "https://claude.ai/code/artifact/d5badda0-7ec9-43df-b73f-a903613a55c0",
        desc: "買家流失74%、營收降23.3%；黑卡回頭率四產品最高，直播是「久久一次但一次就有效」",
      },
    ],
    "代謝錠" => [
      {
        title: "代謝錠今年 vs 去年：誰沒有回來買",
        date: Date.new(2026, 8, 17),
        url: "https://claude.ai/code/artifact/e3dc40f4-3e94-4e8b-a23d-ea67eeea24ea",
        desc: "分月曲線＋18場直播時間軸＋卡別回頭率拆解流失原因，附建議行動",
      },
    ],
    "穀胱甘肽" => [
      {
        title: "新品上市總覽：穀胱甘肽・益生菌・冰晶番茄",
        date: Date.new(2026, 8, 17),
        url: "https://claude.ai/code/artifact/3ca8ec38-cf69-4d3f-9495-b32beb707556#glutathione",
        desc: "2026年上市，尚無去年可比較；上市→回落→第二場再衝量的雙峰型，久久一次才有效",
      },
    ],
    "益生菌" => [
      {
        title: "新品上市總覽：穀胱甘肽・益生菌・冰晶番茄",
        date: Date.new(2026, 8, 17),
        url: "https://claude.ai/code/artifact/3ca8ec38-cf69-4d3f-9495-b32beb707556#probiotic",
        desc: "2026年上市，尚無去年可比較；三個新品裡曝光頻率最高、買氣最持續，表現最健康",
      },
    ],
    "美白" => [
      {
        title: "美白今年 vs 去年：誰沒有回來買",
        date: Date.new(2026, 8, 17),
        url: "https://claude.ai/code/artifact/d3c084c2-c1f0-43f2-96b0-987a0e3a1c35",
        desc: "2026年零直播曝光、買家流失95.6%，但換產品的541人消費力反增4倍，回頭率四產品最低(4.4%)",
      },
    ],
    "魚油" => [
      {
        title: "魚油今年 vs 去年：誰沒有回來買",
        date: Date.new(2026, 8, 17),
        url: "https://claude.ai/code/artifact/c84bce93-fd72-42d0-bf3d-8dd72627f9b7",
        desc: "買家流失74.2%但62.9%只是換產品、消費力反增5.6倍，是分析過產品裡最溫和的個案",
      },
    ],
    "清纖粉" => [
      {
        title: "清纖粉今年 vs 去年：買家流動全貌",
        date: Date.new(2026, 8, 17),
        url: "https://claude.ai/code/artifact/34bc6b62-fcb1-4f4a-93a7-cb69a069ea2d",
        desc: "唯一買家數(+50.2%)、營收(+97.5%)都成長的產品，但舊客流失68.1%被新客量體蓋過，健檢報告",
      },
    ],
    "私密粉" => [
      {
        title: "私密粉：上市後買家流動",
        date: Date.new(2026, 8, 17),
        url: "https://claude.ai/code/artifact/c7876022-34ff-43e1-9611-986c8985b219",
        desc: "2025/09上市，尚無完整年度可比較；首月買家40.7%有回購，但從未有過穩定專場曝光節奏",
      },
    ],
    "蝦紅素" => [
      {
        title: "蝦紅素今年 vs 去年：誰沒有回來買",
        date: Date.new(2026, 8, 17),
        url: "https://claude.ai/code/artifact/1ed30b0e-5905-4ce8-a01b-3ffc793875f6",
        desc: "2025年3場專場今年掛零，買家流失76.1%，跟代謝錠/膠原同樣是失去專屬曝光型",
      },
    ],
    "維DK鈣" => [
      {
        title: "維DK鈣：上市後買家流動",
        date: Date.new(2026, 8, 17),
        url: "https://claude.ai/code/artifact/052b4201-a059-4a92-9167-bd5dd42157ed",
        desc: "連續3個月(6~8月)零訂單，2025/12上市尚無完整年度可比較，需優先確認停售原因",
      },
    ],
    "面膜" => [
      {
        title: "面膜今年 vs 去年：買家流動全貌",
        date: Date.new(2026, 8, 17),
        url: "https://claude.ai/code/artifact/578ea80a-ff11-40e5-83c2-f59abc1d7ed9",
        desc: "營收YTD成長219%但買家數僅+13.5%，成長主要靠客單價拉高（可能來自母親節組合）",
      },
    ],
    "冰晶番茄" => [
      {
        title: "新品上市總覽：穀胱甘肽・益生菌・冰晶番茄",
        date: Date.new(2026, 8, 17),
        url: "https://claude.ai/code/artifact/3ca8ec38-cf69-4d3f-9495-b32beb707556#iced_tomato",
        desc: "2026/07/24才上市，不到一個月資料，太新無法判斷趨勢，記錄起跑點供之後追蹤",
      },
    ],
  }.freeze

  # 每個產品報告的重點數字摘要，手動整理自對應報告的分析結果。
  # new_customers：2026 年新客數（該產品去年沒買過、今年才買）；新上市產品沒有「去年」基準，留 nil。
  # retention_pct：舊客回頭率（去年買過、今年也買的比例）；新上市產品用首購回購率替代時會在 note 註明。
  # status：:growing 買家/營收雙成長｜:watch 買家流失但營收靠客單價撐住｜:declining 買家營收都在流失｜:new 2026年新上市
  SUMMARY = [
    { product: "代謝錠",   status: :declining, new_customers: 705, retention_pct: 25.4, note: "失去專屬直播場次，2026年0場主打" },
    { product: "膠原蛋白", status: :declining, new_customers: 190, retention_pct: 10.5, note: "缺貨92天＋失去專場，跌幅四產品最深" },
    { product: "薑黃",     status: :watch,     new_customers: 597, retention_pct: 26.4, note: "買家流失73.6%，但大宗送贈拉高客單價使營收+17.3%" },
    { product: "全能",     status: :declining, new_customers: 509, retention_pct: 26.0, note: "久久才主打一次，黑卡回頭率四產品最高" },
    { product: "美白",     status: :declining, new_customers: 44,  retention_pct: 4.4,  note: "2026年零曝光，回頭率全產品最低" },
    { product: "魚油",     status: :declining, new_customers: 151, retention_pct: 25.8, note: "流失中最溫和，62.9%只是換產品沒有真的流失" },
    { product: "清纖粉",   status: :growing,   new_customers: 425, retention_pct: 31.9, note: "唯一買家數、營收雙成長，回頭率也最高" },
    { product: "私密粉",   status: :new,       new_customers: nil, retention_pct: 40.7, note: "2025/09上市；首購回購率尚可，缺穩定專場" },
    { product: "蝦紅素",   status: :declining, new_customers: 203, retention_pct: 23.9, note: "2025年3場專場，2026年掛零" },
    { product: "維DK鈣",   status: :new,       new_customers: nil, retention_pct: nil,  note: "2025/12上市；連續3個月(6~8月)零訂單，待確認原因" },
    { product: "面膜",     status: :growing,   new_customers: 254, retention_pct: 25.2, note: "營收+219%，主要靠客單價拉高" },
    { product: "穀胱甘肽", status: :new,       new_customers: nil, retention_pct: nil,  note: "2026/01上市；上市→回落→再衝量的雙峰型" },
    { product: "益生菌",   status: :new,       new_customers: nil, retention_pct: nil,  note: "2026/02上市；三個新品裡曝光最頻繁、買氣最穩" },
    { product: "冰晶番茄", status: :new,       new_customers: nil, retention_pct: nil,  note: "2026/07才上市，資料太新無法判斷趨勢" },
  ].freeze

  STATUS_LABEL = {
    growing: "成長中", watch: "營收撐住但買家流失", declining: "流失中", new: "新品/待觀察"
  }.freeze

  def index
    @reports_by_product = REPORTS
    @summary = SUMMARY
    @status_label = STATUS_LABEL
  end
end
