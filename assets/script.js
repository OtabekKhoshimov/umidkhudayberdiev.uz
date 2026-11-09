(function () {
  var root = document.documentElement;

  // ---------- Kirill → Lotin (o'zbek imlosi) ----------
  var MAP = {
    "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "ё": "yo", "ж": "j", "з": "z", "и": "i",
    "й": "y", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r", "с": "s",
    "т": "t", "у": "u", "ф": "f", "х": "x", "ц": "s", "ч": "ch", "ш": "sh", "щ": "sh", "ъ": "ʼ",
    "ы": "i", "ь": "", "э": "e", "ю": "yu", "я": "ya", "ў": "oʻ", "қ": "q", "ғ": "gʻ", "ҳ": "h"
  };
  var VOWELS = "аеёиоуэюяўaeiou";
  var isUpper = function (c) { return c !== c.toLowerCase(); };
  var isLetter = function (c) { return !!c && c.toLowerCase() !== c.toUpperCase(); };

  function toLatin(text) {
    var out = "";
    for (var i = 0; i < text.length; i++) {
      var ch = text[i], lo = ch.toLowerCase(), prev = text[i - 1] || "", next = text[i + 1] || "";
      var t;
      if (lo === "е") {
        var start = !isLetter(prev);
        t = start || VOWELS.indexOf(prev.toLowerCase()) >= 0 || prev.toLowerCase() === "ъ" || prev.toLowerCase() === "ь" ? "ye" : "e";
      } else if (lo === "ц") {
        t = VOWELS.indexOf(prev.toLowerCase()) >= 0 ? "ts" : "s";
      } else if (MAP.hasOwnProperty(lo)) {
        t = MAP[lo];
      } else {
        out += ch;
        continue;
      }
      if (isUpper(ch) && t) {
        // "ШАХС" → "SHAXS", lekin "Шахс" → "Shaxs"
        var allCaps = (isLetter(next) && isUpper(next)) || (isLetter(prev) && isUpper(prev) && !(isLetter(next) && !isUpper(next)));
        t = allCaps ? t.toUpperCase() : t.charAt(0).toUpperCase() + t.slice(1);
      }
      out += t;
    }
    return out;
  }
  window.toLatin = toLatin;

  var originals = [];
  function walk(node, fn) {
    if (node.nodeType === 3) return fn(node);
    if (node.nodeType !== 1) return;
    var tag = node.tagName;
    if (tag === "SCRIPT" || tag === "STYLE" || node.hasAttribute("data-keep")) return;
    for (var c = node.firstChild; c; c = c.nextSibling) walk(c, fn);
  }
  function setScript(latin) {
    if (latin) {
      if (!originals.length) {
        walk(document.body, function (n) {
          if (/[Ѐ-ӿ]/.test(n.nodeValue)) originals.push([n, n.nodeValue]);
        });
        document.querySelectorAll("[placeholder],[alt],[aria-label]").forEach(function (el) {
          ["placeholder", "alt", "aria-label"].forEach(function (a) {
            var v = el.getAttribute(a);
            if (v && /[Ѐ-ӿ]/.test(v)) originals.push([el, v, a]);
          });
        });
        originals.push([document, document.title, "title"]);
      }
      originals.forEach(function (o) {
        if (o[2] === "title") document.title = toLatin(o[1]);
        else if (o[2]) o[0].setAttribute(o[2], toLatin(o[1]));
        else o[0].nodeValue = toLatin(o[1]);
      });
      root.classList.add("lotin");
      root.lang = "uz-Latn";
    } else {
      originals.forEach(function (o) {
        if (o[2] === "title") document.title = o[1];
        else if (o[2]) o[0].setAttribute(o[2], o[1]);
        else o[0].nodeValue = o[1];
      });
      root.classList.remove("lotin");
      root.lang = "uz-Cyrl";
    }
    try { localStorage.setItem("yozuv", latin ? "lotin" : "kiril"); } catch (e) {}
  }

  var saved = null;
  try { saved = localStorage.getItem("yozuv"); } catch (e) {}
  if (saved === "lotin") setScript(true);
  root.classList.remove("lotin-wait");

  var toggle = document.getElementById("scriptToggle");
  if (toggle) toggle.addEventListener("click", function () { setScript(!root.classList.contains("lotin")); });

  // ---------- Mobil menyu ----------
  var menuBtn = document.getElementById("menuBtn");
  if (menuBtn) {
    menuBtn.addEventListener("click", function () {
      var open = document.body.classList.toggle("menu-open");
      menuBtn.setAttribute("aria-expanded", open);
    });
    document.querySelectorAll("#nav a").forEach(function (a) {
      a.addEventListener("click", function () { document.body.classList.remove("menu-open"); });
    });
  }

  // ---------- Maqolalar: qidiruv va "Yana ko'rsatish" ----------
  var cards = document.getElementById("cards");
  if (cards) {
    var items = Array.prototype.slice.call(cards.children);
    var search = document.getElementById("search");
    var more = document.getElementById("more");
    var empty = document.getElementById("empty");
    var PAGE = 18, shown = PAGE;
    var norm = function (s) { return toLatin(s.toLowerCase()).replace(/[ʻʼ'‘’`]/g, ""); };
    var keys = items.map(function (el) { return norm(el.getAttribute("data-search") || ""); });

    function render() {
      var q = norm(search.value.trim());
      var matches = 0;
      items.forEach(function (el, i) {
        var ok = !q || keys[i].indexOf(q) >= 0;
        if (ok) matches++;
        el.hidden = !ok || (!q && matches > shown);
      });
      more.hidden = !!q || items.length <= shown;
      empty.hidden = matches > 0;
    }
    search.addEventListener("input", render);
    more.addEventListener("click", function () { shown += PAGE; render(); });
    render();
  }
})();
