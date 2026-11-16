# Telegram kanaldan postlarni olib, saytni qayta quradi.
#
#   ruby tools/sync.rb          # yangi postlarni olish + saytni qurish
#   ruby tools/sync.rb --full   # kanal tarixini boshidan to'liq olish
#   ruby tools/sync.rb --build  # internetga chiqmasdan faqat qurish
#
# Faqat Ruby standart kutubxonasi ishlatiladi (GitHub Actions'da ham, Mac'da ham ishlaydi).

require "net/http"
require "uri"
require "json"
require "fileutils"
require "time"
require "cgi"
require "yaml"
require "digest"

ROOT = File.expand_path("..", __dir__)
SITE = JSON.parse(File.read(File.join(ROOT, "data/site.json"), encoding: "UTF-8"))
POSTS_FILE = File.join(ROOT, "data/posts.json")
HIDDEN_FILE = File.join(ROOT, "data/hidden.json")
TPL_DIR = File.join(ROOT, "tools/templates")
CHANNEL = SITE["telegram"]
MIN_LENGTH = SITE["min_article_length"] || 350

# ---------- Telegram'dan olish ----------

def http_get(url, limit = 5)
  uri = URI(url)
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 20, read_timeout: 40) do |h|
    h.get(uri.request_uri, "User-Agent" => "Mozilla/5.0 (site-sync)", "Accept-Language" => "uz,ru;q=0.8")
  end
  if res.is_a?(Net::HTTPRedirection) && limit > 0
    return http_get(URI.join(url, res["location"]).to_s, limit - 1)
  end
  raise "HTTP #{res.code} #{url}" unless res.is_a?(Net::HTTPSuccess)
  res.body.force_encoding("UTF-8")
end

def decode(s)
  CGI.unescapeHTML(s.gsub("&#33;", "!"))
end

# Telegram matnidagi HTML'ni xavfsiz, sodda HTML'ga aylantiradi.
def clean_html(raw)
  h = raw.dup
  h.gsub!(%r{<i class="emoji"[^>]*><b>(.*?)</b></i>}m, '\1')
  h.gsub!(%r{<tg-emoji[^>]*>(.*?)</tg-emoji>}m, '\1')
  h.gsub!(%r{<br\s*/?>}, "\n")
  out = +""
  h.scan(%r{(<[^>]+>)|([^<]+)}m) do |tag, text|
    if text
      out << text
    elsif tag =~ %r{\A<a\s[^>]*href="([^"]+)"}
      href = decode(Regexp.last_match(1))
      out << (href =~ %r{\A(https?:|tg:|mailto:)} ? %(<a href="#{CGI.escapeHTML(href)}" target="_blank" rel="noopener">) : "<a>")
    elsif tag =~ %r{\A<(/?)(b|strong|i|em|u|s|del|code|pre|blockquote)\b[^>]*>\z}
      t = { "strong" => "b", "em" => "i", "del" => "s" }[Regexp.last_match(2)] || Regexp.last_match(2)
      out << "<#{Regexp.last_match(1)}#{t}>"
    elsif tag == "</a>"
      out << "</a>"
    end
  end
  out.gsub("&#33;", "!").strip
end

def plain(html)
  decode(html.gsub(/<[^>]+>/, "")).strip
end

def parse_page(html)
  html.split('class="tgme_widget_message_wrap').drop(1).map do |b|
    id = b[/data-post="[^"\/]+\/(\d+)"/, 1] or next
    next if b.include?("tgme_widget_message_forwarded_from")
    raw = b[%r{<div class="tgme_widget_message_text[^"]*"[^>]*>(.*?)</div>}m, 1].to_s
    html_text = clean_html(raw)
    photo = b[/tgme_widget_message_photo_wrap[^>]*background-image:url\('([^']+)'\)/, 1]
    video = b.include?("tgme_widget_message_video")
    {
      "id" => id.to_i,
      "date" => b[/datetime="([^"]+)"/, 1],
      "html" => html_text,
      "photo_url" => photo,
      "has_video" => video,
      "views" => b[/tgme_widget_message_views">([^<]*)/, 1],
    }
  end.compact
end

def fetch(full:)
  db = File.exist?(POSTS_FILE) ? JSON.parse(File.read(POSTS_FILE, encoding: "UTF-8")) : []
  by_id = db.to_h { |p| [p["id"], p] }
  url = "https://t.me/s/#{CHANNEL}"
  pages = 0
  loop do
    items = parse_page(http_get(url))
    pages += 1
    break if items.empty?
    fresh = 0
    items.each do |it|
      fresh += 1 unless by_id.key?(it["id"])
      old = by_id[it["id"]] || {}
      by_id[it["id"]] = old.merge(it) { |k, o, n| k == "photo_url" && n.nil? ? o : n }
    end
    min_id = items.map { |i| i["id"] }.min
    break if min_id <= 1 || pages >= 200
    break if !full && fresh.zero?
    url = "https://t.me/s/#{CHANNEL}?before=#{min_id}"
    sleep 0.6
  end
  posts = by_id.values.sort_by { |p| -p["id"] }
  File.write(POSTS_FILE, JSON.pretty_generate(posts) + "\n")
  puts "Telegram: #{pages} sahifa o'qildi, bazada #{posts.size} post."
  posts
end

# ---------- Maqolalarni tayyorlash ----------

LANGS = %w[uz ru en ar].freeze
I18N = YAML.safe_load(File.read(File.join(ROOT, "data/i18n.yml"), encoding: "UTF-8"))
MONOGRAM = { "uz" => "УХ", "ru" => "УХ", "en" => "UK", "ar" => "UK" }.freeze

def prefix(lang)
  lang == "uz" ? "" : "#{lang}/"
end

def local_date(iso, lang)
  t = Time.parse(iso).getlocal("+05:00")
  m = I18N[lang]["months"][t.month - 1]
  case lang
  when "en" then "#{m} #{t.day}, #{t.year}"
  when "uz" then "#{t.day} #{m}, #{t.year}"
  else "#{t.day} #{m} #{t.year}"
  end
end

def truncate(s, n)
  return s if s.length <= n
  cut = s[0, n].sub(/\s+\S*\z/, "")
  cut.sub(/[\s,.;:!?—–-]+\z/, "") + "…"
end

def download_image(post)
  return nil unless post["photo_url"]
  rel = "assets/posts/#{post["id"]}.jpg"
  path = File.join(ROOT, rel)
  unless File.exist?(path)
    begin
      File.binwrite(path, http_get(post["photo_url"]))
    rescue => e
      warn "Rasm yuklanmadi (#{post["id"]}): #{e.message}"
      return nil
    end
  end
  rel
end

def articles(posts)
  hidden = File.exist?(HIDDEN_FILE) ? JSON.parse(File.read(HIDDEN_FILE)) : []
  posts.map do |p|
    next if hidden.include?(p["id"])
    text = plain(p["html"].to_s)
    next if text.length < MIN_LENGTH
    lines = p["html"].split("\n").map(&:strip)
    # Faqat heshteglardan iborat qatorlar maqola teglari bo'ladi, matndan olib tashlanadi
    tags = []
    lines = lines.reject do |l|
      t = plain(l).delete("​")
      next false unless t =~ /\A(#[[:word:]]+[\s,]*)+\z/
      tags.concat(t.scan(/#([[:word:]]+)/).flatten)
    end
    body_lines = lines.dup
    body_lines.shift while body_lines.any? && plain(body_lines.first).empty?
    first = plain(body_lines.first.to_s)
    # Salomlashuv qatori sarlavha bo'lmaydi
    if first =~ /\A(ассалом|assalom)/i && first.length < 120
      title_src = plain(body_lines.drop(1).find { |l| !plain(l).empty? }.to_s)
    else
      title_src = first
    end
    title_src = title_src.sub(/\A[^[:alnum:]«"“(]+/, "")
    if title_src == first.sub(/\A[^[:alnum:]«"“(]+/, "") && first.length.between?(8, 140)
      title = title_src
      body_lines.shift
    else
      title = truncate(title_src, 90)
    end
    paras = body_lines.join("\n").split(/\n\s*\n/).map(&:strip).reject { |x| plain(x).empty? }
    body = paras.map { |x| "<p>#{x.gsub("\n", "<br>")}</p>" }.join("\n")
    words = text.split(/\s+/).size
    {
      "id" => p["id"], "title" => title, "body" => body, "tags" => tags.uniq,
      "excerpt" => excerpt_of(body), "iso" => p["date"],
      "image" => download_image(p), "minutes" => [(words / 180.0).ceil, 1].max,
    }
  end.compact
end

def excerpt_of(body_html)
  truncate(plain(body_html.gsub(/<br>|<\/p>/, " ")).gsub(/\s+/, " "), 180)
end

# ---------- Maqolalar tarjimasi ----------

TR_DIR = File.join(ROOT, "data/translations")

def source_hash(a)
  Digest::SHA1.hexdigest(a["title"] + "\n" + a["body"])[0, 12]
end

def load_translation(lang, a)
  f = File.join(TR_DIR, lang, "#{a["id"]}.json")
  return nil unless File.exist?(f)
  JSON.parse(File.read(f, encoding: "UTF-8"))
end

# Yangi maqolalarni (translate_from_id dan boshlab) ru/en/ar tillariga tarjima qiladi.
# ANTHROPIC_API_KEY bo'lmasa yoki anthropic gem o'rnatilmagan bo'lsa, jim o'tkazib yuboradi.
def translate_new(arts)
  return unless ENV["ANTHROPIC_API_KEY"].to_s != ""
  begin
    require_relative "translate"
  rescue LoadError => e
    warn "Tarjima o'tkazib yuborildi: #{e.message}"
    return
  end
  from_id = SITE["translate_from_id"] || Float::INFINITY
  limit = SITE["translate_per_run"] || 10
  done = 0
  arts.select { |a| a["id"] >= from_id }.sort_by { |a| a["id"] }.each do |a|
    (LANGS - ["uz"]).each do |lang|
      tr = load_translation(lang, a)
      next if tr && tr["source"] == source_hash(a)
      return puts("Tarjima: bu safar limitga yetildi (#{limit}).") if done >= limit
      result = Translator.translate(a["title"], a["body"], lang)
      next unless result
      FileUtils.mkdir_p(File.join(TR_DIR, lang))
      File.write(File.join(TR_DIR, lang, "#{a["id"]}.json"),
                 JSON.pretty_generate(result.merge("source" => source_hash(a))) + "\n")
      done += 1
      puts "Tarjima qilindi: #{a["id"]} → #{lang}"
    end
  end
end

def articles_for(lang, arts)
  return arts if lang == "uz"
  arts.map do |a|
    tr = load_translation(lang, a) or next
    a.merge("title" => tr["title"], "body" => tr["body_html"], "excerpt" => excerpt_of(tr["body_html"]),
            "tags" => [], "translated" => true)
  end.compact
end

# ---------- Shablon (mustache'ning soddalashtirilgan ko'rinishi) ----------
# {{x}} — xavfsiz (escape), {{{x}}} — HTML sifatida, {{a.b}} — ichki maydon,
# {{#x}}...{{/x}} — ro'yxat yoki shart, {{^x}}...{{/x}} — teskari shart, {{.}} — joriy element.

def lookup(stack, name)
  return stack.last if name == "."
  head, *rest = name.split(".")
  scope = stack.reverse.find { |s| s.is_a?(Hash) && s.key?(head) }
  return nil unless scope
  rest.reduce(scope[head]) { |v, k| v.is_a?(Hash) ? v[k] : nil }
end

def blank?(v)
  v.nil? || v == false || v == "" || (v.respond_to?(:empty?) && v.empty?)
end

def render(str, stack)
  stack = [stack] unless stack.is_a?(Array)
  out = str.gsub(/\{\{([#^])([\w.]+)\}\}\n?(.*?)\{\{\/\2\}\}\n?/m) do
    kind, name, inner = Regexp.last_match(1), Regexp.last_match(2), Regexp.last_match(3)
    v = lookup(stack, name)
    if kind == "^"
      blank?(v) ? render(inner, stack) : ""
    elsif blank?(v)
      ""
    elsif v.is_a?(Array)
      v.map { |item| render(inner, stack + [item]) }.join
    else
      render(inner, v.is_a?(Hash) ? stack + [v] : stack)
    end
  end
  out.gsub(/\{\{\{([\w.]+)\}\}\}|\{\{([\w.]+)\}\}/) do
    raw, safe = Regexp.last_match(1), Regexp.last_match(2)
    raw ? lookup(stack, raw).to_s : CGI.escapeHTML(lookup(stack, safe).to_s)
  end
end

def tpl(name)
  File.read(File.join(TPL_DIR, name), encoding: "UTF-8")
end

def abs_url(path)
  SITE["url"].to_s.sub(%r{/\z}, "") + "/" + path
end

def write_page(path, html)
  out = File.join(ROOT, path, "index.html")
  FileUtils.mkdir_p(File.dirname(out))
  File.write(out, html)
end

def esc(s)
  CGI.escapeHTML(s.to_s)
end

def card(a, lang, home)
  img = a["image"] ? %(<img src="#{a["root"]}#{a["image"]}" alt="" loading="lazy">) : %(<span class="card-mark">«</span>)
  <<~HTML
    <a class="card" href="#{home}maqolalar/#{a["id"]}/" data-search="#{esc(([a["title"], a["excerpt"]] + a["tags"]).join(" ").downcase)}">
      <div class="card-img">#{img}</div>
      <div class="card-body">
        <div class="meta">#{local_date(a["iso"], lang)} · #{a["minutes"]} #{I18N[lang]["minutes"]}</div>
        <h3>#{esc(a["title"])}</h3>
        <p>#{esc(a["excerpt"])}</p>
      </div>
    </a>
  HTML
end

# Admin panel rasmlarni "/assets/img/x.jpg" deb yozadi; sahifalar nisbiy yo'l bilan ishlaydi
def strip_slashes(v)
  case v
  when Hash then v.transform_values { |x| strip_slashes(x) }
  when Array then v.map { |x| strip_slashes(x) }
  when String then v.start_with?("/assets/") ? v[1..-1] : v
  else v
  end
end

def build(posts)
  arts = articles(posts)
  translate_new(arts)
  urls = []

  # Eski maqola sahifalarini tozalash (yashirilganlar o'chib ketishi uchun)
  LANGS.each do |lang|
    Dir.glob(File.join(ROOT, prefix(lang), "maqolalar/*/")).each { |d| FileUtils.rm_rf(d) if File.basename(d) =~ /\A\d+\z/ }
  end

  per_lang = LANGS.to_h { |l| [l, articles_for(l, arts)] }

  LANGS.each do |lang|
    c = strip_slashes(YAML.safe_load(File.read(File.join(ROOT, "content/#{lang}.yml"), encoding: "UTF-8")))
    t = I18N[lang]
    list = per_lang[lang]

    # path: sahifaning saytdagi yo'li ("", "ru/", "ru/maqolalar/12/")
    page = lambda do |path, title:, description:, body:, image: "assets/img/og.jpg", type: "website", alt_paths: nil|
      depth = path.count("/")
      root = "../" * depth
      home = root + prefix(lang)
      alt_paths ||= LANGS.to_h { |l| [l, prefix(l) + path.sub(/\A#{Regexp.escape(prefix(lang))}/, "")] }
      ctx = {
        "t" => t, "c" => c, "root" => root, "home" => home, "title" => title, "description" => description,
        "canonical" => abs_url(path), "og_image" => abs_url(image), "og_type" => type,
        "is_uz" => lang == "uz", "is_ar" => lang == "ar", "monogram" => MONOGRAM[lang],
        "telegram" => CHANNEL, "year" => Time.now.year,
        "alternates" => alt_paths.map { |l, p| { "hreflang" => I18N[l]["html_lang"], "href" => abs_url(p) } },
        "langs" => LANGS.map { |l| { "code" => l, "label" => I18N[l]["label"], "href" => root + alt_paths[l], "active" => l == lang } },
      }
      ctx["content"] = body
      write_page(path, render(tpl("layout.html"), ctx))
      urls << path
    end

    # Bosh sahifa
    total = arts.size.to_s
    contact = c["contact"] || {}
    body = render(tpl("home.html"), [{
      "t" => t, "c" => c, "root" => "../" * prefix(lang).count("/"), "telegram" => CHANNEL,
      "stats" => c["stats"].map { |s| s.merge("value" => s["value"].to_s.gsub("{count}", total)) },
      "activity" => c["activity"]["items"].each_with_index.map { |it, i| it.merge("num" => format("%02d", i + 1)) },
      "about_text" => c["about"]["text"].to_s.split(/\n\s*\n/).map { |p| "<p>#{esc(p.strip)}</p>" }.join("\n"),
      "quote" => esc(c["cta"]["quote"]).gsub("\n", "<br>"),
      "has_latest" => list.any?,
      "latest" => list.first(6).map { |a| card(a.merge("root" => "../" * prefix(lang).count("/")), lang, "") }.join,
      "has_contacts" => %w[phone email telegram_personal].any? { |k| !blank?(contact[k]) },
      "phone_link" => contact["phone"].to_s.gsub(/[^\d+]/, ""),
      "tg_personal" => contact["telegram_personal"].to_s.sub(/\A@/, "").sub(%r{\Ahttps?://t\.me/}, ""),
    }])
    page.call(prefix(lang), title: c["seo"]["title"], description: c["seo"]["description"], body: body)

    # Maqolalar ro'yxati
    lpath = prefix(lang) + "maqolalar/"
    root = "../" * lpath.count("/")
    cards = list.map { |a| card(a.merge("root" => root), lang, "") }.join
    body = render(tpl("list.html"), [{
      "t" => t, "c" => c, "root" => root, "cards" => cards, "no_articles" => list.empty?,
      "total" => list.empty? ? "" : t["total"].to_s.gsub("{count}", list.size.to_s), "uz_articles_label" => t["uz_articles"],
    }])
    page.call(lpath, title: "#{c["articles"]["page_heading"]} — #{c["name"]}", description: c["articles"]["page_lead"],
              body: body)

    # Har bir maqola
    list.each_with_index do |a, i|
      apath = "#{lpath}#{a["id"]}/"
      aroot = "../" * apath.count("/")
      alt = LANGS.to_h { |l| [l, per_lang[l].any? { |x| x["id"] == a["id"] } ? "#{prefix(l)}maqolalar/#{a["id"]}/" : "#{prefix(l)}maqolalar/"] }
      body = render(tpl("article.html"), [{
        "t" => t, "c" => c, "root" => aroot, "telegram" => CHANNEL, "translated" => a["translated"],
        "a" => a.merge("date" => local_date(a["iso"], lang)),
        "newer" => i.positive? ? list[i - 1] : nil, "older" => list[i + 1],
        "share" => CGI.escape(abs_url(apath)),
      }])
      page.call(apath, title: "#{a["title"]} — #{c["name"]}", description: a["excerpt"], type: "article",
                image: a["image"] || "assets/img/og.jpg", body: body, alt_paths: alt)
    end
    puts "Qurildi (#{lang}): #{list.size} ta maqola."
  end

  File.write(File.join(ROOT, "sitemap.xml"),
             %(<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n) +
             urls.map { |u| "  <url><loc>#{abs_url(u)}</loc></url>\n" }.join + "</urlset>\n")
end

posts = if ARGV.include?("--build")
          JSON.parse(File.read(POSTS_FILE, encoding: "UTF-8"))
        else
          fetch(full: ARGV.include?("--full"))
        end
build(posts)
