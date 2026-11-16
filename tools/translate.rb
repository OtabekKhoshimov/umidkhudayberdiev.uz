# Maqolani Claude API orqali rus, ingliz yoki arab tiliga tarjima qiladi.
# GitHub Actions'da ishlaydi: `gem install anthropic`, kalit — ANTHROPIC_API_KEY secret.

require "anthropic"
require "json"

module Translator
  MODEL = :"claude-opus-5-5"
  LANG_NAMES = { "ru" => "Russian", "en" => "English", "ar" => "Modern Standard Arabic" }.freeze

  SCHEMA = {
    type: "object",
    properties: {
      title: { type: "string" },
      body_html: { type: "string" },
    },
    required: %w[title body_html],
    additionalProperties: false,
  }.freeze

  SYSTEM = <<~TXT.freeze
    You translate articles by Umid Khudayberdiev, an Uzbek insurance and finance expert who writes
    reflective essays about life, family, career, faith and self-improvement for his Telegram channel.
    The source is in Uzbek (usually Cyrillic script, sometimes Latin) and may quote Russian.

    Translate the title and the article body into the requested language so it reads as if it were
    written in that language: keep the author's warm, direct, first-person voice, his short paragraphs
    and rhetorical questions. Keep proverbs and sayings meaningful in the target language rather than
    word-for-word; keep names of people, companies and places as commonly written in that language.

    The body is simple HTML. Keep exactly the same tags and structure (<p>, <br>, <b>, <i>, <u>, <s>,
    <a href="..."> with unchanged href, <blockquote>, <code>) and translate only the text between them.
    Keep emoji where they are. Return only the translation, with no notes.
  TXT

  def self.client
    @client ||= Anthropic::Client.new
  end

  # { "title" => ..., "body_html" => ... } yoki nil (xato bo'lsa — keyingi safar qayta uriniladi)
  def self.translate(title, body_html, lang)
    message = client.messages.create(
      model: MODEL,
      max_tokens: 16_000,
      output_config: { effort: "medium", format: { type: "json_schema", schema: SCHEMA } },
      system: SYSTEM,
      messages: [{
        role: "user",
        content: "Target language: #{LANG_NAMES.fetch(lang)}\n\nTitle:\n#{title}\n\nBody HTML:\n#{body_html}",
      }]
    )
    unless message.stop_reason == :end_turn
      warn "Tarjima to'liq emas (#{lang}): stop_reason=#{message.stop_reason}"
      return nil
    end
    text = message.content.select { |b| b.type == :text }.map(&:text).join
    data = JSON.parse(text)
    return nil if data["title"].to_s.strip.empty? || data["body_html"].to_s.strip.empty?
    { "title" => data["title"].strip, "body_html" => data["body_html"].strip }
  rescue Anthropic::Errors::APIStatusError => e
    warn "Tarjima xatosi (#{lang}): #{e.class} #{e.message}"
    nil
  rescue Anthropic::Errors::APIConnectionError, JSON::ParserError => e
    warn "Tarjima xatosi (#{lang}): #{e.class} #{e.message}"
    nil
  end
end
