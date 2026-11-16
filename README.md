# Umid Xudoyberdiyev — shaxsiy sayt (umidkhudayberdiev.uz)

Statik sayt (GitHub Pages), 4 tilda: oʻzbekcha (asosiy, Kirill/Lotin), ruscha `/ru/`, inglizcha `/en/`, arabcha `/ar/`.

## Qanday ishlaydi
- **Maqolalar** @umidkhudayberdiev Telegram kanalidan olinadi. GitHub Actions har 2 soatda `tools/sync.rb` ni ishga tushiradi.
- **Tarjima**: `translate_from_id` (data/site.json) dan boshlab yangi maqolalar Claude API orqali ru/en/ar ga tarjima qilinadi
  (`tools/translate.rb`, natija `data/translations/<til>/<id>.json`). Buning uchun repo Settings → Secrets'da `ANTHROPIC_API_KEY` boʻlishi kerak.
  Bitta ishga tushishda koʻpi bilan `translate_per_run` ta tarjima qilinadi.
- **Sayt matnlari** (biografiya, ish joylari, faoliyat, rasmlar) `content/<til>.yml` da. Ustoz ularni
  [Pages CMS](https://app.pagescms.org) orqali tahrirlaydi (sozlama: `.pages.yml`). Saqlangach sayt 1–3 daqiqada yangilanadi.
- Menyu va tugmalar yozuvlari: `data/i18n.yml`. Dizayn: `assets/style.css`, shablonlar: `tools/templates/`.
- Postni saytdan yashirish: raqamini `data/hidden.json` ga qoʻshing.

## Qoʻlda ishga tushirish

    ruby tools/sync.rb          # yangi postlar + tarjima + qurish
    ruby tools/sync.rb --full   # butun tarix
    ruby tools/sync.rb --build  # faqat qayta qurish
