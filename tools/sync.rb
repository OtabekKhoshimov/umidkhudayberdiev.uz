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

MONTHS = %w[январ феврал март апрел май июн июл август сентябр октябр ноябр декабр].freeze

def uz_date(iso)
  t = Time.parse(iso).getlocal("+05:00")
  "#{t.day} #{MONTHS[t.month - 1]}, #{t.year}"
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
    rest = plain(body_lines.join(" ")).gsub(/\s+/, " ")
    words = text.split(/\s+/).size
    {
      "id" => p["id"], "title" => title, "body" => body, "tags" => tags.uniq,
      "excerpt" => truncate(rest, 180), "date" => uz_date(p["date"]), "iso" => p["date"],
      "image" => download_image(p), "minutes" => [(words / 180.0).ceil, 1].max,
    }
  end.compact
end

# ---------- Sahifalarni qurish ----------

def tpl(name)
  File.read(File.join(TPL_DIR, name), encoding: "UTF-8")
end

def fill(str, vars)
  str.gsub(/\{\{(\w+)\}\}/) { vars.fetch(Regexp.last_match(1)) { "" }.to_s }
end

def esc(s)
  CGI.escapeHTML(s.to_s)
end

def abs_url(path)
  SITE["url"].to_s.sub(%r{/\z}, "") + "/" + path
end

def page(file, root:, title:, description:, content:, image: "assets/img/og.jpg", path: "", type: "website")
  html = fill(tpl("layout.html"), {
    "root" => root, "title" => esc(title), "description" => esc(description),
    "canonical" => esc(abs_url(path)), "og_image" => esc(abs_url(image)), "og_type" => type,
    "content" => content, "year" => Time.now.year, "telegram" => CHANNEL, "ga" => SITE["ga"].to_s,
  })
  out = File.join(ROOT, file)
  FileUtils.mkdir_p(File.dirname(out))
  File.write(out, html)
end

def card(a, root)
  img = a["image"] ? %(<img src="#{root}#{a["image"]}" alt="" loading="lazy">) : %(<span class="card-mark">«</span>)
  <<~HTML
    <a class="card" href="#{root}maqolalar/#{a["id"]}/" data-search="#{esc(([a["title"], a["excerpt"]] + a["tags"]).join(" ").downcase)}">
      <div class="card-img">#{img}</div>
      <div class="card-body">
        <div class="meta">#{a["date"]} · #{a["minutes"]} дақиқа</div>
        <h3>#{esc(a["title"])}</h3>
        <p>#{esc(a["excerpt"])}</p>
      </div>
    </a>
  HTML
end

def build(posts)
  arts = articles(posts)
  # Eski maqola sahifalarini tozalash (yashirilganlar o'chib ketishi uchun)
  Dir.glob(File.join(ROOT, "maqolalar/*/")).each { |d| FileUtils.rm_rf(d) if File.basename(d) =~ /\A\d+\z/ }

  page("index.html", root: "", title: SITE["title"], description: SITE["description"],
       content: fill(tpl("home.html"), {
         "root" => "", "latest" => arts.first(6).map { |a| card(a, "") }.join,
         "count" => arts.size, "telegram" => CHANNEL,
       }))

  page("maqolalar/index.html", root: "../", path: "maqolalar/",
       title: "Мақолалар — #{SITE["name"]}", description: "#{SITE["name"]}нинг барча мақолалари.",
       content: fill(tpl("list.html"), {
         "root" => "../", "cards" => arts.map { |a| card(a, "../") }.join, "count" => arts.size, "telegram" => CHANNEL,
       }))

  arts.each_with_index do |a, i|
    newer = i.positive? ? arts[i - 1] : nil
    older = arts[i + 1]
    nav = +""
    nav << %(<a class="prev" href="../#{older["id"]}/"><span>← Олдинги</span>#{esc(older["title"])}</a>) if older
    nav << %(<a class="next" href="../#{newer["id"]}/"><span>Кейинги →</span>#{esc(newer["title"])}</a>) if newer
    hero = a["image"] ? %(<figure class="article-img"><img src="../../#{a["image"]}" alt=""></figure>) : ""
    page("maqolalar/#{a["id"]}/index.html", root: "../../", path: "maqolalar/#{a["id"]}/", type: "article",
         title: "#{a["title"]} — #{SITE["name"]}", description: a["excerpt"], image: a["image"] || "assets/img/og.jpg",
         content: fill(tpl("article.html"), {
           "root" => "../../", "title" => esc(a["title"]), "date" => a["date"], "iso" => a["iso"],
           "minutes" => a["minutes"], "body" => a["body"], "hero" => hero, "nav" => nav,
           "tags" => a["tags"].map { |t| %(<span class="tag">##{esc(t)}</span>) }.join,
           "tg_link" => "https://t.me/#{CHANNEL}/#{a["id"]}", "telegram" => CHANNEL,
           "share" => CGI.escape(abs_url("maqolalar/#{a["id"]}/")),
         }))
  end

  urls = ["", "maqolalar/"] + arts.map { |a| "maqolalar/#{a["id"]}/" }
  File.write(File.join(ROOT, "sitemap.xml"),
             %(<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n) +
             urls.map { |u| "  <url><loc>#{abs_url(u)}</loc></url>\n" }.join + "</urlset>\n")
  puts "Qurildi: #{arts.size} ta maqola."
end

posts = if ARGV.include?("--build")
          JSON.parse(File.read(POSTS_FILE, encoding: "UTF-8"))
        else
          fetch(full: ARGV.include?("--full"))
        end
build(posts)
