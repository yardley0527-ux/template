if KoreanBrandLead.any?
  puts "Korean brand leads already seeded, skipping"
else

lador_email = <<~EMAIL
  Dear LADOR Global Business Team,

  Greetings from Taiwan.

  My name is Serena, representing Sheng Ting International Biotechnology (苼莛國際生技), a Taiwan-based health and beauty company specializing in women's wellness, beauty, and lifestyle products.

  Our official website:
  https://www.yardley.tw/

  Sheng Ting operates an established e-commerce and social commerce business in Taiwan. We have experience in brand management, online retail, influencer collaboration, group-buy campaigns, social media content, digital advertising, membership operations, and customer retention.

  In addition to our direct-to-consumer e-commerce business, we have experience working with major pharmacy and retail channels in Taiwan, as well as female-focused online communities and group-buy markets.

  We have been impressed by LADOR's professional haircare positioning, product quality, distinctive fragrance collections, and strong market potential among Taiwanese female consumers. We believe LADOR's products are highly compatible with our customer base and content-driven sales model.

  We are therefore interested in discussing a potential partnership with LADOR in Taiwan.

  For the initial stage, we would like to explore an official limited-time group-buy campaign featuring selected LADOR products, including:

  Perfumed Hair Oil
  Perfumed Hair Shampoo
  Perfumed Hair Treatment
  Root Re-Boot Shampoo
  Damage Protector Acid Shampoo and Conditioner
  Keratin LPP Haircare Series

  Our proposed cooperation may include:

  Limited-time official group-buy campaigns
  Social media and short-form video promotion
  Influencer and KOL collaborations
  Livestream and educational content
  Meta and Instagram advertising
  Customer membership and repurchase campaigns
  Long-term e-commerce or distribution cooperation in Taiwan

  Before preparing a detailed campaign proposal, we would appreciate your guidance on the following questions:

  Does LADOR currently have an exclusive distributor or authorized importer in Taiwan?
  Is LADOR open to working directly with a Taiwanese company on official group-buy, social commerce, or e-commerce campaigns?
  If LADOR already has an authorized Taiwan distributor, could you please introduce us to the appropriate local contact for partnership discussions?
  Would products be supplied directly by LADOR Korea or through your authorized Taiwan distributor?
  Could you provide your wholesale or group-buy quotation, minimum order quantity, payment terms, and delivery conditions?
  Does LADOR offer a trial campaign or pre-order-based cooperation model for the first collaboration?
  Are product samples available for product evaluation and content production?
  Can LADOR provide official marketing materials, product information, ingredient documentation, authorization documents, and regulatory documents required for the Taiwan market?
  Are there recommended retail prices, minimum advertised prices, or other pricing policies that partners must follow?
  Would LADOR be open to discussing a longer-term Taiwan e-commerce, social commerce, or distribution partnership after a successful initial campaign?

  For the first campaign, we are considering a curated haircare proposal featuring LADOR's fragrance haircare products and solutions for different scalp and hair conditions.

  Our team can manage campaign planning, Taiwanese market positioning, Chinese-language content creation, social media promotion, advertising, influencer collaboration, customer service, and membership-based repurchase campaigns.

  We would be pleased to provide our company introduction, audience profile, proposed campaign plan, expected order volume, marketing resources, and relevant cooperation experience for your review.

  We look forward to exploring a long-term partnership with LADOR and introducing your professional Korean haircare products to more consumers in Taiwan.

  Thank you for your time. We look forward to hearing from you.

  Best regards,

  Serena
  Sheng Ting International Biotechnology
  苼莛國際生技

  Official Website: https://www.yardley.tw/
  Instagram: https://www.instagram.com/chloechao0527/
  Email: yardley0527@gmail.com
EMAIL

KoreanBrandLead.create!(
  product_name: "LADOR（韓國髮品）",
  source_url: "https://mghair.my1shop.com/coco_1618_LADOR",
  contact_channel: "Email（LADOR Global Business Team）",
  contacted: true,
  contacted_at: Date.new(2026, 8, 6),
  email_content: lador_email,
  replied: false,
  notes: "已寄出提案信，詢問台灣代理狀況、報價、樣品；尚未收到回覆"
)

olle_shot_notes = <<~NOTES
  【情報來源】Instagram 限時動態，發布帳號 @goodalicia，2026/8/8 截圖（限動顯示約13小時前發布）
  【情報性質】競品開團情報／下一個潛在開發產品
  【目前狀態】對方已赴韓國洽談合作，預計近期開團
  【正式合作品牌】尚未公開
  【照片中的品牌】疑似 LATIB Olive Lemon Shot，應為比較產品，並非已確認的合作品牌

  限動原文整理：
  @goodalicia 表示，這次前往韓國的主要目的之一，是洽談橄欖油檸檬飲合作。她已喝過韓國市面上多個品牌，認為目前洽談的產品口味非常好。

  根據限動透露，預計合作的產品具有以下特點：
  - 韓國大型超市的自有品牌
  - 目前沒有查到添加防腐劑
  - 原料與配方品質被認為優於照片中的熱門品牌
  - 口味與照片中的比較品牌有明顯差距
  - 合作已進入洽談階段
  - 預計近期開團，但尚未公布確切日期、售價與組合
NOTES

KoreanBrandLead.create!(
  product_name: "韓國橄欖油檸檬飲／Olle Shot（競品情報，正式合作品牌尚未公開）",
  source_url: nil,
  contact_channel: nil,
  contacted: false,
  email_content: nil,
  replied: false,
  notes: olle_shot_notes
)

KoreanBrandLead.create!(
  product_name: "REJUALL（Dr. Reju-All PDRN 藍銅修護精華）",
  source_url: nil,
  contact_channel: nil,
  contacted: false,
  email_content: nil,
  replied: false,
  notes: "從 IG @jazz10242008 截圖得知台灣已有團媽（小渝）直接跟總代理談合作，8/18 開第7團；同截圖顯示 LADOR 9/10 也有其他團媽首團開賣，代表 LADOR 台灣已有其他管道在賣，需一併確認我們接洽的窗口是否為官方/總代理"
)

  puts "Seeded #{KoreanBrandLead.count} Korean brand leads"
end
