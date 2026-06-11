# 清除舊資料再重新 seed
Livestream.destroy_all

def p(name_with_price)
  # parse "全能（1盒）1699 元" → { name: "全能（1盒）", price: 1699 }
  name_with_price = name_with_price.strip.gsub(/\n/, ' ')
  if (m = name_with_price.match(/^(.+?)(\d+)\s*元\s*$/))
    { name: m[1].strip, price: m[2].to_i }
  else
    { name: name_with_price, price: 0 }
  end
end

LIVESTREAM_DATA = [
  # ── 2024 ──────────────────────────────────────────────────────────────────
  {
    date: "2024-08-09",
    products: [
      p("全能（1盒）1699 元"),
      p("薑黃（1盒）1599 元"),
      p("代謝錠（1盒）1599 元"),
    ],
    gifts: [
      { description: "一元購 大魚肚按摩棒 不用消費即可下單 下次寄出", highlight: true },
    ]
  },
  {
    date: "2024-09-13",
    products: [
      p("美白（1盒）1799 元"),
    ],
    gifts: [
      { description: "直播下單送眼部按摩棒不挑款", highlight: true },
    ]
  },
  {
    date: "2024-10-14",
    products: [
      p("全能（1盒）1699 元"),
    ],
    gifts: [
      { description: "滿3/5/8瓶送購物金100/200/300元", highlight: false },
      { description: "送美容棒", highlight: false },
    ]
  },
  {
    date: "2024-11-08",
    products: [
      { name: "美白1+全能1+代謝1+薑黃1", price: 6680 },
    ],
    gifts: [
      { description: "送大眼小臉按摩棒+隨身藥盒", highlight: false },
    ]
  },
  {
    date: "2024-11-22",
    products: [
      p("家庭代謝（1盒）3080 元"),
    ],
    gifts: [
      { description: "送拉提海馬器+隨身藥盒", highlight: false },
      { description: "限定時間下單滿3瓶送瘦腿神器按摩儀", highlight: true },
      { description: "買3送藥盒1　買5再送藥盒1", highlight: false },
      { description: "買6送刮油神器", highlight: false },
    ]
  },
  {
    date: "2024-12-13",
    products: [
      p("薑黃（1盒）1599 元"),
    ],
    gifts: [
      { description: "送除水淋巴器", highlight: false },
      { description: "買3送藥盒1　買5再送藥盒1", highlight: false },
      { description: "買6送刮油神器", highlight: false },
    ]
  },
  {
    date: "2024-12-23",
    products: [
      p("美白（1盒）1799 元"),
      p("酵素（1盒）1588 元"),
    ],
    gifts: [
      { description: "美白1送藥盒", highlight: false },
      { description: "美白3送瘦腿神器", highlight: false },
    ]
  },

  # ── 2025 ──────────────────────────────────────────────────────────────────
  {
    date: "2025-01-05",
    products: [
      p("膠原蛋白（1盒）2980 元"),
    ],
    gifts: [
      { description: "送美胸棒+紅包袋", highlight: false },
      { description: "買5送療癒小物大拼盤", highlight: false },
    ]
  },
  {
    date: "2025-01-13",
    products: [
      p("代謝（1盒）3080 元"),
      p("全能（1盒）1699 元"),
      p("美容儀（1個）6980 元"),
    ],
    gifts: [
      { description: "送雙推按摩器", highlight: false },
    ]
  },
  {
    date: "2025-02-20",
    products: [
      { name: "美白1+膠原蛋白1", price: 4850 },
    ],
    gifts: [
      { description: "送雙推按摩器", highlight: false },
    ]
  },
  {
    date: "2025-03-10",
    products: [
      { name: "薑黃1+全能1", price: 3380 },
    ],
    gifts: [
      { description: "送藥盒+腹部按摩器+小禮物 不限次數", highlight: false },
    ]
  },
  {
    date: "2025-03-21",
    products: [
      p("蝦紅素（1盒）1899 元"),
      p("蝦紅素（3盒）5509 元"),
      p("蝦紅素（6盒）10899 元"),
      p("蝦紅素（10盒送1）18900 元"),
    ],
    gifts: [
      { description: "買1送藥盒", highlight: false },
      { description: "買3送藥盒1+晴明穴按摩器1", highlight: false },
      { description: "買6送藥盒2+晴明穴按摩器2", highlight: false },
    ]
  },
  {
    date: "2025-04-11",
    products: [
      p("膠原蛋白（1盒）2780 元"),
      p("膠原蛋白（2盒）5200 元"),
      p("薑黃（1盒）1599 元"),
      p("美白（1盒）1799 元"),
    ],
    gifts: [
      { description: "買2送彎月刮痧棒", highlight: false },
      { description: "買3送藥盒", highlight: false },
      { description: "滿10000元送洗臉機", highlight: false },
    ]
  },
  {
    date: "2025-04-22",
    products: [
      p("代謝（1盒）2880 元"),
      p("代謝（2盒）5700 元"),
    ],
    gifts: [
      { description: "送消水腫美容棒", highlight: false },
      { description: "滿5000元送藥盒", highlight: false },
      { description: "滿10000元送洗臉機", highlight: false },
    ]
  },
  {
    date: "2025-05-09",
    products: [
      p("全能（1盒）1690 元"),
      p("塑身褲（1雙）3080 元"),
      p("塑身褲（2雙）5980 元"),
    ],
    gifts: [
      { description: "全能3送藥盒", highlight: false },
      { description: "全能6送洗臉機", highlight: false },
      { description: "全能12送全能1", highlight: false },
      { description: "滿1萬/2萬/3萬送購物金100/200/300元", highlight: false },
    ]
  },
  {
    date: "2025-05-20",
    products: [
      p("蝦紅素（1盒）1890 元"),
      p("蝦紅素（3盒）5670 元"),
      p("蝦紅素（6盒）11340 元"),
      p("蝦紅素（10盒送1）18900 元"),
      p("美白（10瓶送1）18050 元"),
    ],
    gifts: [
      { description: "蝦紅素3送藥盒", highlight: false },
      { description: "蝦紅素6送睛漾按摩棒", highlight: false },
      { description: "滿1萬/2萬/3萬送購物金100/200/300元", highlight: false },
    ]
  },
  {
    date: "2025-06-09",
    products: [
      p("美白（1瓶）1799 元"),
      p("美白（2瓶）3570 元"),
      p("美白（3瓶）5270 元"),
      p("美白（6瓶）10120 元"),
      p("美白（10瓶送1）18050 元"),
    ],
    gifts: [
      { description: "滿5000元送按摩梳", highlight: false },
    ]
  },
  {
    date: "2025-06-20",
    products: [
      p("魚油（1盒）1890 元"),
      p("魚油（3盒）5670 元"),
      p("魚油（6盒）11340 元"),
      p("魚油（10盒送1）18900 元"),
      { name: "薑黃2+代謝2", price: 9320 },
    ],
    gifts: [
      { description: "送按摩梳", highlight: false },
      { description: "滿5000元送水壺", highlight: false },
    ]
  },
  {
    date: "2025-07-04",
    products: [
      p("薑黃（1瓶）1599 元"),
      p("薑黃（6瓶）9500 元"),
      p("代謝（1瓶）3080 元"),
      p("代謝（6瓶）18400 元"),
      { name: "薑黃2+代謝2", price: 9320 },
    ],
    gifts: [
      { description: "滿3000送藥盒", highlight: false },
      { description: "滿5000送水壺", highlight: false },
    ]
  },
  {
    date: "2025-07-22",
    products: [
      p("薑黃（1瓶）1599 元"),
      p("薑黃（6瓶）9500 元"),
      p("代謝（1瓶）3080 元"),
      p("代謝（6瓶）18400 元"),
      { name: "薑黃2+代謝2", price: 9320 },
      p("清纖粉（10盒送1）18560 元"),
    ],
    gifts: [
      { description: "滿3000送藥盒", highlight: false },
      { description: "滿5000送水壺", highlight: false },
    ]
  },
  {
    date: "2025-08-04",
    products: [
      p("清纖粉（1盒）1799 元"),
      p("清纖粉（2盒）3570 元"),
      p("清纖粉（3盒）5270 元"),
      p("清纖粉（6盒）10242 元"),
      p("清纖粉（10盒送1）18560 元"),
      { name: "膠原蛋白 單包體驗", price: 120 },
      p("面膜（1盒）990 元"),
      p("面膜（3盒）2880 元"),
      p("面膜（6盒）5600 元"),
      p("面膜（10盒送1）9900 元"),
      { name: "面膜（10盒送1+洗臉機1）", price: 10000 },
    ],
    gifts: []
  },
  {
    date: "2025-08-21",
    products: [
      p("膠原蛋白（1盒）2980 元"),
      p("膠原蛋白（3盒）8850 元"),
      p("膠原蛋白（6盒）17450 元"),
      p("膠原蛋白（10盒送1）31500 元"),
      p("美白（1瓶）1799 元"),
      p("清纖粉（1盒）1799 元"),
      p("美白（3瓶）5270 元"),
      p("美白（6瓶）10120 元"),
      p("美白（10瓶）16750 元"),
      { name: "全能10+美白10", price: 32000 },
    ],
    gifts: [
      { description: "滿5000送搖搖杯", highlight: false },
    ]
  },
  {
    date: "2025-09-04",
    products: [
      p("全能（1盒）1690 元"),
      p("全能（3盒）5050 元"),
      p("全能（6盒）10050 元"),
      p("全能（10盒）16700 元"),
    ],
    gifts: []
  },
  {
    date: "2025-09-15",
    products: [
      p("私密粉（1盒）1980 元"),
      p("私密粉（3盒）5900 元"),
      p("私密粉（6盒）11500 元"),
    ],
    gifts: [
      { description: "滿5000送喝水神器", highlight: false },
    ]
  },
  {
    date: "2025-10-09",
    products: [
      p("代謝（1瓶）3080 元"),
      p("代謝（3瓶）9200 元"),
      p("代謝（6瓶）18400 元"),
      p("代謝（10瓶）29990 元"),
    ],
    gifts: [
      { description: "滿1000送海苔片", highlight: false },
      { description: "滿3000送藥盒", highlight: false },
      { description: "滿5000送喝水神器", highlight: false },
    ]
  },
  {
    date: "2025-10-20",
    products: [
      p("蝦紅素（1盒）1899 元"),
      p("蝦紅素（3盒）5400 元"),
      p("蝦紅素（6盒）10500 元"),
      p("蝦紅素（10盒）17000 元"),
      p("薑黃（10瓶）15900 元"),
    ],
    gifts: [
      { description: "滿1000送海苔片", highlight: false },
      { description: "滿3000送藥盒", highlight: false },
      { description: "滿5000送喝水神器", highlight: false },
    ]
  },
  {
    date: "2025-11-07",
    products: [
      p("薑黃（1瓶）1690 元"),
      p("薑黃（3瓶）5050 元"),
      { name: "薑黃（6瓶送削削臉按摩組）", price: 10050 },
      { name: "薑黃（1瓶送膠原蛋白）", price: 11111 },
      p("薑黃（10瓶）15900 元"),
      { name: "魚油2+薑黃2+代謝1+膠原蛋白1", price: 11111 },
    ],
    gifts: [
      { description: "滿1000送海苔片", highlight: false },
      { description: "滿5000送藥盒", highlight: false },
      { description: "滿15000送膠原蛋白", highlight: false },
      { description: "滿20000送膠原蛋白1+清纖粉1", highlight: false },
    ]
  },
  {
    date: "2025-11-22",
    products: [
      p("魚油（1盒）1890 元"),
      p("魚油（3盒）5170 元"),
      { name: "魚油（6盒送洗臉機）", price: 10320 },
      { name: "美白1+膠原蛋白1", price: 4300 },
    ],
    gifts: [
      { description: "滿1000送海苔片", highlight: false },
      { description: "滿5000送鬆鬆梳", highlight: false },
      { description: "滿15000送膠原蛋白", highlight: false },
    ]
  },
  {
    date: "2025-12-07",
    products: [
      p("美白（1瓶）1799 元"),
      p("美白（3瓶）4800 元"),
      p("美白（6瓶）8999 元"),
      p("全能（1盒）1690 元"),
      p("全能（3盒）5050 元"),
      p("全能（6盒）10050 元"),
      p("全能（10盒）16700 元"),
      { name: "全能1+DK鈣1", price: 3300 },
      { name: "全能2+DK鈣2", price: 6450 },
      { name: "全能3+DK鈣3", price: 9650 },
    ],
    gifts: [
      { description: "滿額送膠原蛋白", highlight: false },
    ]
  },
  {
    date: "2025-12-19",
    products: [
      p("DK鈣（1盒）1690 元"),
      p("DK鈣（3盒）5050 元"),
      p("DK鈣（6盒）10050 元"),
      p("DK鈣（10盒）16700 元"),
      p("清纖粉（10盒）16870 元"),
    ],
    gifts: [
      { description: "滿額送膠原蛋白", highlight: false },
    ]
  },
  {
    date: "2025-12-24",
    products: [
      p("清纖粉（1盒）1799 元"),
      p("清纖粉（2盒）3579 元"),
      p("清纖粉（3盒）5270 元"),
      p("清纖粉（6盒）10242 元"),
    ],
    gifts: [
      { description: "滿5000送刮痧板", highlight: false },
      { description: "滿15000送膠原蛋白", highlight: false },
    ]
  },

  # ── 2026 ──────────────────────────────────────────────────────────────────
  {
    date: "2026-01-09",
    products: [
      { name: "代謝＋膠原", price: 5000 },
      p("薑黃（1瓶）1690 元"),
      p("薑黃（3瓶）5050 元"),
      p("薑黃（6瓶）10050 元"),
      p("薑黃（10瓶）15900 元"),
    ],
    gifts: []
  },
  {
    date: "2026-01-23",
    products: [
      p("專利穀胱甘肽（1盒）1980 元"),
      { name: "專利穀胱甘肽（3盒）贈NMN膠囊（1瓶）", price: 5780 },
      { name: "專利穀胱甘肽（6盒）贈NMN膠囊（2瓶）", price: 11400 },
      p("代謝錠（2瓶送1）6760 元"),
    ],
    gifts: [
      { description: "滿5000元送淋巴醒水棒", highlight: false },
      { description: "滿10000元送正貨膠原蛋白", highlight: false },
    ]
  },
  {
    date: "2026-02-06",
    products: [
      p("益生菌（1盒）1950 元"),
      { name: "益生菌（3盒送全能1）", price: 5800 },
      { name: "益生菌（6盒送全能2）", price: 11680 },
      p("代謝錠（2瓶送1）6760 元"),
    ],
    gifts: [
      { description: "滿15000元送薑黃（1瓶）", highlight: false },
      { description: "滿30000元送薑黃（2瓶）", highlight: false },
      { description: "滿45000元送薑黃（3瓶）", highlight: false },
    ]
  },
  {
    date: "2026-02-25",
    products: [
      p("薑黃（1盒）1690 元"),
      p("薑黃（3盒）5050 元"),
      p("薑黃（6盒）10050 元"),
      p("薑黃（10盒）15900 元"),
      p("清纖粉（1盒）1780 元"),
      p("清纖粉（3盒）5170 元"),
      p("清纖粉（5盒送1）9900 元"),
      p("清纖粉（10盒送3）19800 元"),
      p("益生菌（3盒）5800 元"),
      p("益生菌（6盒）11500 元"),
      p("代謝錠（2瓶送1）6760 元"),
    ],
    gifts: [
      { description: "下單送多功能刮痧板", highlight: false },
      { description: "滿15000元送薑黃 可累贈", highlight: false },
    ]
  },
  {
    date: "2026-03-05",
    products: [
      p("膠原（1盒）2980 元"),
      p("膠原（2盒）5760 元"),
      p("膠原（3盒）8300 元"),
      p("膠原（4盒）10400 元"),
      p("益生菌（3盒）5800 元"),
      p("益生菌（6盒）11500 元"),
    ],
    gifts: [
      { description: "滿15000元送清纖粉 可累贈", highlight: false },
    ]
  },
  {
    date: "2026-03-20",
    products: [
      p("全能膠囊（1盒）1690 元"),
      p("全能膠囊（3盒）5050 元"),
      p("全能膠囊（6盒）10050 元"),
      p("私密處粉（1盒）1980 元"),
      p("私密處粉（3盒）5800 元"),
      p("私密處粉（6盒）10500 元"),
      p("益生菌（1盒）2050 元"),
      p("益生菌（2盒）4300 元"),
      p("益生菌（3盒）5700 元"),
      p("益生菌（5盒）9250 元"),
      { name: "魚油、蝦紅素、D 加購價", price: 999 },
    ],
    gifts: [
      { description: "滿5000元送小章魚棒", highlight: false },
      { description: "滿25000元送代謝錠 可累贈", highlight: false },
    ]
  },
  {
    date: "2026-03-27",
    products: [
      { name: "魚油、蝦紅素、D 任選3件", price: 3600 },
    ],
    gifts: [
      { description: "滿5000元送小章魚棒", highlight: false },
      { description: "滿25000元送代謝錠 可累贈", highlight: false },
    ]
  },
  {
    date: "2026-04-10",
    products: [
      p("薑黃（1瓶）1690 元"),
      p("薑黃（3瓶）5050 元"),
      p("薑黃（6瓶）10050 元"),
      p("薑黃（10瓶送1）15900 元"),
      p("薑黃（20瓶送2+清纖粉1）31800 元"),
      { name: "清纖粉、私密粉、益生菌 任選3件", price: 5200 },
    ],
    gifts: [
      { description: "滿5000元送經絡按摩梳", highlight: false },
      { description: "滿15000元送薑黃 可累贈", highlight: false },
      { description: "滿20000元送清纖粉", highlight: false },
    ]
  },
  {
    date: "2026-04-24",
    products: [
      p("代謝錠（1瓶）2980 元"),
      p("代謝錠（2瓶）5200 元"),
      p("代謝錠（4瓶）9900 元"),
      p("代謝錠（6瓶）13800 元"),
      { name: "代謝錠1+薑黃1 送黑薑/清纖粉", price: 5260 },
    ],
    gifts: [
      { description: "滿5000元送除水排酸棒", highlight: false },
      { description: "滿15000元送薑黃", highlight: false },
      { description: "滿20000元送清纖粉", highlight: false },
    ]
  },
  {
    date: "2026-05-08",
    products: [
      { name: "蝦紅素、維生素D鈣K、薑黃、瘦身粉、益生菌、私密粉 任選3件", price: 5200 },
      p("膠原蛋白（2盒）5200 元"),
      p("代謝錠（2瓶）5200 元"),
      p("面膜（1盒）990 元"),
      p("面膜（3盒）2700 元"),
      p("面膜（6盒）4950 元"),
      p("面膜（10盒）7600 元"),
      { name: "代謝+薑黃+薑黃", price: 5260 },
      { name: "代謝+薑黃+清纖粉", price: 5260 },
    ],
    gifts: [
      { description: "滿5000元送隨身玻璃水壺", highlight: false },
      { description: "滿15000元送薑黃", highlight: false },
      { description: "滿20000元送清纖粉", highlight: false },
    ]
  },
  {
    date: "2026-05-22",
    products: [
      p("專利穀胱甘肽（5盒送1）9900 元"),
      { name: "專利穀胱甘肽（10盒送2+面膜1）", price: 19800 },
      p("代謝錠（2瓶）5200 元"),
      p("代謝錠（4瓶）9900 元"),
      p("代謝錠（6瓶）13800 元"),
    ],
    gifts: [
      { description: "滿5000元送小臉刮刮木", highlight: false },
      { description: "滿15000元送益生菌", highlight: false },
      { description: "滿20000元送穀胱甘肽", highlight: false },
    ]
  },
  {
    date: "2026-06-05",
    products: [
      p("全能（1瓶）1880 元"),
      p("全能（2瓶）3500 元"),
      p("全能（5瓶）8400 元"),
      p("全能（8瓶）13200 元"),
      p("全能（10瓶送2）18960 元"),
      p("全能（17瓶送3）29700 元"),
    ],
    gifts: [
      { description: "滿5000元送貼紙+個人藥盒", highlight: false },
      { description: "滿15000元送全能", highlight: false },
      { description: "滿20000元送穀胱甘肽", highlight: false },
    ]
  },
]

LIVESTREAM_DATA.each do |data|
  ls = Livestream.create!(date: data[:date])

  data[:products].each_with_index do |prod, i|
    ls.livestream_products.create!(name: prod[:name], price: prod[:price], position: i)
  end

  data[:gifts].each_with_index do |gift, i|
    ls.livestream_gifts.create!(description: gift[:description], highlight: gift[:highlight], position: i)
  end
end

puts "Seeded #{LIVESTREAM_DATA.size} livestreams, #{LivestreamProduct.count} products, #{LivestreamGift.count} gifts"
