# Umid Xudoyberdiyev — shaxsiy sayt

Statik sayt (GitHub Pages). Maqolalar **@umidkhudayberdiev** Telegram kanalidan avtomatik olinadi:
GitHub Actions har 2 soatda `tools/sync.rb` ni ishga tushiradi, yangi postlarni oladi, sahifalarni quradi va saqlaydi.

- 350 belgidan uzun, forward qilinmagan postlar — maqola bo'ladi.
- Biror postni saytdan yashirish: uning raqamini `data/hidden.json` ga qo'shing (masalan `[1431, 1436]`).
- Bosh sahifa matni: `tools/templates/home.html`. Dizayn: `assets/style.css`.
- Sayt sozlamalari (manzil, kanal): `data/site.json`.

Qo'lda ishga tushirish:

    ruby tools/sync.rb          # yangi postlar
    ruby tools/sync.rb --full   # butun tarix
    ruby tools/sync.rb --build  # faqat qayta qurish
