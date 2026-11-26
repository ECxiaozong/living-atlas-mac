(() => {
  const root = document.getElementById("answer");
  const md = markdownit({ html: false, breaks: true, linkify: false });
  md.disable(["image", "link", "autolink", "reference"]);
  // Allow CJK fullwidth punctuation adjacent to **bold** delimiters without altering source text offsets.
  const baseScanDelims = md.inline.State.prototype.scanDelims;
  const cjkClosePunct = /[：；，。！？、）》」』】”’]/;
  const cjkOpenPunct = /[（《「『【“‘]/;
  md.inline.State.prototype.scanDelims = function(start, canSplitWord) {
    const res = baseScanDelims.call(this, start, canSplitWord);
    if (canSplitWord && this.src.charCodeAt(start) === 0x2a) {
      if (start > 0 && cjkClosePunct.test(this.src[start - 1])) res.can_close = true;
      const after = start + res.length;
      if (after < this.posMax && cjkOpenPunct.test(this.src[after])) res.can_open = true;
    }
    return res;
  };
  const escape = md.utils.escapeHtml;
  md.use(AtlasTex.tex, {
    delimiters: "all",
    render(source, displayMode) {
      const tag = displayMode ? "div" : "span";
      try {
        // WebKit lays out native MathML, including fractions and matrices, offline.
        const math = katex.renderToString(source, {
          output: "mathml", displayMode, trust: false, throwOnError: true,
          maxSize: 12, maxExpand: 500
        });
        return `<${tag} class="math-${displayMode ? "block" : "inline"}">${math}</${tag}>`;
      } catch {
        return `<${tag} class="math-source">${escape(source)}</${tag}>`;
      }
    }
  });
  // Keep an unfinished bracket delimiter readable when streaming pauses or stops.
  md.inline.ruler.before("escape", "pending_math", (state, silent) => {
    const opener = state.src.slice(state.pos, state.pos + 2);
    if (opener !== "\\(" && opener !== "\\[") return false;
    if (!silent) state.pending += opener;
    state.pos += 2;
    return true;
  });
  md.renderer.rules.table_open = () => '<div class="table-wrap"><table>';
  md.renderer.rules.table_close = () => "</table></div>";
  md.renderer.rules.fence = (tokens, i) => {
    const token = tokens[i];
    const language = token.info.trim().split(/\s+/)[0];
    const label = language ? `<div class="language">${escape(language)}</div>` : "";
    return `<section>${label}<pre><code>${escape(token.content)}</code></pre></section>`;
  };

  installAtlasCallouts(md);

  function renderBlocks(value) {
    const env = {};
    const tokens = md.parse(value, env);
    const offsets = [0];
    for (const match of value.matchAll(/\r\n?|\n/g)) offsets.push(match.index + match[0].length);
    const result = [];
    let start = 0;
    for (let i = 0; i < tokens.length; i++) {
      if (tokens[i].level !== 0 || tokens[i].nesting === 1) continue;
      const first = tokens[start];
      const offset = first.map && offsets[first.map[0]];
      const end = first.map && (offsets[first.map[1]] ?? value.length);
      const source = first.map && value.slice(offset, end).replace(/(?:\r\n?|\n)$/, "");
      const old = blocks[result.length];
      // Link references are disabled. An unchanged top-level block can reuse its
      // markup, including expensive math layout, even as the final block grows.
      if (source != null && old?.source === source && old.type === first.type) {
        result.push({...old, offset});
      } else {
        const html = md.renderer.render(tokens.slice(start, i + 1), md.options, env);
        result.push({ source, offset, type: first.type, html });
      }
      start = i + 1;
    }
    return result;
  }

  function saveSelection() {
    const selection = getSelection();
    if (!selection.rangeCount || selection.isCollapsed ||
        !root.contains(selection.anchorNode) || !root.contains(selection.focusNode)) return;
    const range = selection.getRangeAt(0);
    const before = document.createRange();
    before.selectNodeContents(root);
    before.setEnd(range.startContainer, range.startOffset);
    return {
      text: range.toString(), offset: before.toString().length,
      anchor: selection.anchorNode, focus: selection.focusNode,
      backward: selection.anchorNode === range.endContainer && selection.anchorOffset === range.endOffset
    };
  }

  function textPoint(offset, container = root, preferNext = false) {
    const walker = document.createTreeWalker(container, NodeFilter.SHOW_TEXT);
    let node, last;
    while ((node = walker.nextNode())) {
      if (offset < node.length || (!preferNext && offset === node.length)) return [node, offset];
      offset -= node.length;
      last = node;
    }
    if (offset === 0 && last) return [last, last.length];
  }

  function restoreSelection(saved) {
    if (!saved?.text || (saved.anchor.isConnected && saved.focus.isConnected)) return;
    const text = root.textContent;
    // Wrapping **selected words** or turning a pipe row into cells removes delimiters.
    // Find the nearest identical selection rather than reusing stale DOM offsets.
    const before = text.lastIndexOf(saved.text, saved.offset);
    const after = text.indexOf(saved.text, saved.offset);
    const offset = before < 0 || (after >= 0 && after - saved.offset < saved.offset - before)
      ? after : before;
    if (offset < 0) return;
    const start = textPoint(offset), end = textPoint(offset + saved.text.length);
    if (start && end) {
      const [anchor, focus] = saved.backward ? [end, start] : [start, end];
      getSelection().setBaseAndExtent(...anchor, ...focus);
    }
  }

  let previous = "", blocks = [], dragging = false, pending;
  const latest = document.getElementById("latest");
  let paused = false, wasStreaming = false;
  const atEnd = () => window.scrollY + window.innerHeight >= document.documentElement.scrollHeight - 3;
  window.addEventListener("scroll", () => { if (wasStreaming && !atEnd()) paused = true; });
  window.addEventListener("wheel", event => { if (event.deltaY < 0) paused = true; }, {passive:true});
  document.addEventListener("selectionchange", () => { if (!getSelection().isCollapsed) paused = true; });
  latest.addEventListener("click", () => {
    getSelection().removeAllRanges();
    latest.hidden = true;
    paused = false;
    window.scrollTo(0, document.documentElement.scrollHeight);
  });
  const activity = window.webkit?.messageHandlers?.atlasActivity;
  let reportedActivity = false;
  function reportActivity() {
    if (!activity) return;
    const selection = getSelection();
    const active = dragging || (!restoredRange && !selection.isCollapsed && root.contains(selection.anchorNode)
      && root.contains(selection.focusNode));
    if (active !== reportedActivity) {
      reportedActivity = active;
      activity.postMessage(active);
    }
  }
  document.addEventListener("selectionchange", reportActivity);
  root.addEventListener("pointerdown", () => { dragging = true; reportActivity(); });
  function release() {
    dragging = false;
    reportActivity();
    if (pending !== undefined) {
      const value = pending;
      pending = undefined;
      window.renderAnswer(...value);
    }
  }
  window.addEventListener("pointerup", release);
  window.addEventListener("pointercancel", release);
  window.addEventListener("blur", release);

  // Map within the actual selected Markdown block. Identical paragraphs can occur
  // more than once and Markdown markup is not part of the rendered selection.
  function sourceOffset(range, text) {
    const children = Array.from(root.children);
    const first = children.findIndex(el => el.contains(range.startContainer));
    const last = children.findIndex(el => el.contains(range.endContainer));
    if (first < 0 || last < first || !blocks[first]?.source || !blocks[last]?.source) return -1;
    const {offset, source} = blocks[first];
    if (first === last && children[first].textContent === source) {
      const before = document.createRange();
      before.selectNodeContents(children[first]);
      before.setEnd(range.startContainer, range.startOffset);
      return offset + before.toString().length;
    }
    const raw = previous.slice(offset, blocks[last].offset + blocks[last].source.length);
    const match = raw.indexOf(text);
    if (match < 0) return -1;
    if (raw.indexOf(text, match + 1) < 0) return offset + match;
    // In a callout, the same phrase may occur in the title and again in the body.
    // Accept its visible ordinal only when the literal source has the same occurrences.
    if (first === last && children[first].matches("aside.callout")) {
      const visible = children[first].textContent;
      const prefix = document.createRange();
      prefix.selectNodeContents(children[first]);
      prefix.setEnd(range.startContainer, range.startOffset);
      const start = prefix.toString().length;
      if (visible.slice(start, start + text.length) === text) {
        let shown = visible.indexOf(text), source = match, candidate = -1;
        while (shown >= 0 && source >= 0) {
          if (shown === start) candidate = source;
          shown = visible.indexOf(text, shown + 1);
          source = raw.indexOf(text, source + 1);
        }
        if (shown < 0 && source < 0 && candidate >= 0) return offset + candidate;
      }
    }
    return -1;
  }

  const ask = document.createElement("button");
  ask.type = "button";
  ask.textContent = "就选句追问";
  ask.id = "ask-fragment";
  ask.hidden = true;
  if (window.webkit?.messageHandlers?.atlasExcerpt) {
    root.after(ask);
    let selectedExcerpt;
    function excerpt(range, text) {
      const start = sourceOffset(range, text);
      const boxes = range.getClientRects();
      const end = boxes[boxes.length - 1];
      return {body: previous, start, end: start < 0 ? -1 : start + text.length,
        x: end?.right ?? 0, y: end?.bottom ?? 0};
    }
    document.addEventListener("selectionchange", () => {
      const wasHidden = ask.hidden;
      const text = saveSelection()?.text;
      if (!text && document.activeElement === ask && selectedExcerpt) return;
      ask.hidden = !text;
      if (wasHidden && !ask.hidden && !restoredRange) {
        window.webkit?.messageHandlers?.atlasTextSelected?.postMessage(true);
      }
      if (!ask.hidden) {
        const rect = getSelection().getRangeAt(0).getClientRects();
        if (!rect.length) return;
        const end = rect[rect.length - 1];
        selectedExcerpt = excerpt(getSelection().getRangeAt(0), text);
        ask.style.left = Math.max(0, Math.min(innerWidth - ask.offsetWidth - 4, end.left)) + "px";
        const below = end.bottom + 2;
        const top = below + ask.offsetHeight <= innerHeight ? below : Math.max(0, end.top - ask.offsetHeight - 2);
        ask.style.top = (scrollY + top) + "px";
      }
    });
    ask.addEventListener("mousedown", event => event.preventDefault());
    ask.addEventListener("click", () => {
      const saved = saveSelection();
      const chosen = saved ? excerpt(getSelection().getRangeAt(0), saved.text) : selectedExcerpt;
      if (chosen && !ask.hidden) window.webkit.messageHandlers.atlasExcerpt.postMessage(chosen);
    });
  }

  // Persistent positions are scoped by the native host to one entrance and answer run.
  // DOM offsets here are UTF-16 units in rendered blocks, separate from source citations.
  const placeHandler = window.webkit?.messageHandlers?.atlasAnswerPlace;
  let place = {}, restoredRange = false;
  function pointInBlock(node, offset) {
    const el = node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement;
    const block = el.closest("article > *");
    if (!block || block.parentElement !== root) return null;
    const prefix = document.createRange();
    prefix.selectNodeContents(block);
    prefix.setEnd(node, offset);
    return {block: Array.prototype.indexOf.call(root.children, block), offset: prefix.toString().length};
  }
  function changePlace(field, value) {
    if (JSON.stringify(place[field] ?? null) === JSON.stringify(value)) return;
    place[field] = value;
    placeHandler.postMessage(JSON.stringify(place));
  }
  function rememberRange(clear = false) {
    if (!placeHandler || dragging) return;
    const sel = getSelection();
    if (sel.isCollapsed || !sel.rangeCount) {
      if (clear) changePlace("range", null);
      return;
    }
    const range = sel.getRangeAt(0);
    if (!root.contains(range.startContainer) || !root.contains(range.endContainer)) return;
    const start = pointInBlock(range.startContainer, range.startOffset);
    const end = pointInBlock(range.endContainer, range.endOffset);
    if (start && end) changePlace("range", {start, end, text: range.toString(),
      backward: sel.anchorNode === range.endContainer && sel.anchorOffset === range.endOffset});
  }
  function resumeRange(saved) {
    const locate = (p, preferNext) => {
      const el = root.children[p.block];
      return el && textPoint(p.offset, el, preferNext);
    };
    const start = locate(saved.start, true), end = locate(saved.end, false);
    if (!start || !end) return;
    const r = document.createRange();
    r.setStart(...start); r.setEnd(...end);
    if (r.toString() !== saved.text) return;
    restoredRange = true;
    const [anchor, focus] = saved.backward ? [end, start] : [start, end];
    getSelection().setBaseAndExtent(...anchor, ...focus);
  }
  function rememberScroll() {
    if (naturalHeight || !root.childElementCount) return;
    let lo = 0, hi = root.childElementCount - 1;
    while (lo < hi) {
      const mid = Math.floor((lo + hi) / 2);
      if (root.children[mid].getBoundingClientRect().bottom <= 0) lo = mid + 1;
      else hi = mid;
    }
    changePlace("scroll", {block: lo, offset: -root.children[lo].getBoundingClientRect().top,
      following: wasStreaming && !paused && atEnd()});
  }
  function resumePlace(initial, toFixed) {
    if (!placeHandler) return;
    if (initial) {
      place = initial;
      if (place.range) resumeRange(place.range);
    }
    if (!naturalHeight && (initial || toFixed) && place.scroll) {
      const el = root.children[place.scroll.block];
      if (el) {
        paused = !place.scroll.following || !!place.range;
        if (!paused && wasStreaming) window.scrollTo(0, document.documentElement.scrollHeight);
        else window.scrollBy(0, el.getBoundingClientRect().top + place.scroll.offset);
      }
    }
  }
  if (placeHandler) {
    window.addEventListener("scroll", rememberScroll, {passive:true});
    document.addEventListener("selectionchange", () => rememberRange());
    window.addEventListener("pointerup", () => rememberRange(true));
    root.addEventListener("click", () => rememberRange(true));
    document.addEventListener("keyup", () => rememberRange(true));
    latest.addEventListener("click", () => rememberRange(true));
    for (const type of ["pointerdown", "keydown"])
      document.addEventListener(type, () => { restoredRange = false; }, true);
  }

  let naturalHeight = false;
  const heightHandler = window.webkit?.messageHandlers?.atlasHeight;
  const heightObserver = heightHandler && new ResizeObserver(() => {
    if (naturalHeight) heightHandler.postMessage(Math.ceil(root.getBoundingClientRect().height) + 16);
  });
  let canvasWheelMode = 0;
  const wheelHandler = window.webkit?.messageHandlers?.atlasPan;
  let wheelTimer = 0, lastLayout = "", lastScrollReport = -Infinity;
  function publishWheelLayout() {
    if (!wheelHandler || !canvasWheelMode) return;
    const page = document.scrollingElement;
    const layout = {
      above: !naturalHeight && page.scrollTop > 1,
      below: !naturalHeight && page.scrollTop + page.clientHeight < page.scrollHeight - 1,
      horizontal: []
    };
    for (const item of root.querySelectorAll("pre,.table-wrap,.math-block")) {
      if (item.scrollWidth <= item.clientWidth + 1) continue;
      const r = item.getBoundingClientRect();
      if (r.bottom >= 0 && r.top <= innerHeight) {
        layout.horizontal.push([r.x, r.y, r.width, r.height, Number(item.scrollLeft > 1),
          Number(item.scrollLeft + item.clientWidth < item.scrollWidth - 1)]);
      }
    }
    const key = JSON.stringify(layout);
    if (key !== lastLayout) { lastLayout = key; wheelHandler.postMessage(layout); }
  }
  function scheduleWheelLayout() {
    if (!wheelHandler || !canvasWheelMode || wheelTimer) return;
    wheelTimer = setTimeout(() => { wheelTimer = 0; publishWheelLayout(); }, 0);
  }
  if (wheelHandler) {
    new ResizeObserver(scheduleWheelLayout).observe(root);
    window.addEventListener("resize", scheduleWheelLayout);
    document.addEventListener("scroll", () => {
      scheduleWheelLayout();
      const now = performance.now();
      if (canvasWheelMode === 2 && now - lastScrollReport > 150) wheelHandler.postMessage("reader-scroll");
      lastScrollReport = now;
    }, true);
  }
  window.renderAnswer = (value, streaming = false, natural = false, picking = false, initialPlace = null, wheelMode = 0) => {
    canvasWheelMode = wheelMode;
    const label = picking ? "把回答选句加入本题" : "就选句追问";
    if (ask.textContent !== label) ask.textContent = label;
    if (dragging) { pending = [value, streaming, natural, picking, initialPlace || pending?.[4], wheelMode]; return; }
    const toFixed = naturalHeight && !natural;
    if (naturalHeight !== natural) {
      naturalHeight = natural;
      document.documentElement.style.overflowY = natural ? "hidden" : "";
      if (natural) {
        heightObserver?.observe(root);
        window.scrollTo(0,0);
        latest.hidden = true;
      } else {
        heightObserver?.disconnect();
      }
    }
    if (value === previous) {
      wasStreaming = streaming;
      resumePlace(initialPlace, toFixed);
      publishWheelLayout();
      return;
    }
    const extending = value.startsWith(previous);
    if (!extending) { paused = false; latest.hidden = true; }
    const live = streaming || wasStreaming;
    const follow = !natural && extending && live && !paused && getSelection().isCollapsed && atEnd();
    wasStreaming = streaming;
    const next = renderBlocks(value);
    const scrollY = window.scrollY;
    let saved;
    next.forEach(({html}, i) => {
      if (html === blocks[i]?.html) return;
      const old = root.children[i];
      const template = document.createElement("template");
      template.innerHTML = html.trim();
      const element = template.content.firstElementChild;
      if (old) {
        if (extending && !saved) saved = saveSelection();
        const scroller = old.matches(".table-wrap, .math-block") ? old : old.querySelector("pre");
        const left = scroller?.scrollLeft || 0;
        old.replaceWith(element);
        if (left) {
          const current = element.matches(".table-wrap, .math-block") ? element : element.querySelector("pre");
          if (current) current.scrollLeft = left;
        }
      } else root.append(element);
    });
    while (root.children.length > next.length) root.lastElementChild.remove();
    restoreSelection(saved);
    if (follow) {
      window.scrollTo(0, document.documentElement.scrollHeight);
    } else {
      if (!natural && extending && live && (paused || !atEnd())) latest.hidden = false;
      if (!extending || window.scrollY !== scrollY) window.scrollTo(0, extending ? scrollY : 0);
    }
    previous = value;
    blocks = next;
    resumePlace(initialPlace, toFixed);
    publishWheelLayout();
  };
})();
