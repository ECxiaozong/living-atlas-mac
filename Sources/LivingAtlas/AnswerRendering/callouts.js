// Both offline readers install this after their own code-fence renderer.
function installAtlasCallouts(md) {
  const labels = new Map([["note", "笔记"], ["tip", "提示"], ["warning", "注意"], ["question", "问题"]]);
  function open(kind, title) {
    const heading = title ? '<div class="callout-title">' + md.utils.escapeHtml(title) + '</div>'
      : '<div class="callout-title" data-label="' + labels.get(kind) + '" aria-label="' + labels.get(kind) + '"></div>';
    return '<aside class="callout callout-' + kind + '">' + heading;
  }
  const fence = md.renderer.rules.fence;
  md.renderer.rules.fence = function(tokens, index, options, env, renderer) {
    const token = tokens[index];
    const kind = /^ad-(note|tip|warning|question)$/i.exec(token.info.trim())?.[1].toLowerCase();
    if (!kind || (env.calloutDepth || 0) >= 12) return fence(tokens, index, options, env, renderer);
    const title = /^title:[ \t]*([^\n]*)(?:\n|$)/i.exec(token.content);
    const body = title ? token.content.slice(title[0].length) : token.content;
    return open(kind, title?.[1].trim()) + md.render(body, {...env, calloutDepth: (env.calloutDepth || 0) + 1}) + '</aside>\n';
  };

  md.core.ruler.before("inline", "atlas_callouts", state => {
    if (!state.src.includes("[!")) return;
    const ts = state.tokens;
    const closeAt = new Map(), stack = [];
    for (let i = 0; i < ts.length; i++) {
      if (ts[i].type === "blockquote_open") stack.push(i);
      else if (ts[i].type === "blockquote_close") closeAt.set(stack.pop(), i);
    }
    for (const [i, end] of closeAt) {
      const quote = ts[i], first = ts[i + 2];
      if (quote.type !== "blockquote_open" || ts[i + 1]?.type !== "paragraph_open" || first?.type !== "inline") continue;
      const header = /^\[!(note|tip|warning|question)\](?:[ \t]+([^\n]*))?(?:\n|$)/i.exec(first.content);
      if (!header) continue;
      quote.type = "atlas_callout_open";
      quote.meta = {kind: header[1].toLowerCase(), title: (header[2] || "").trim()};
      ts[end].type = "atlas_callout_close";
      first.content = first.content.slice(header[0].length);
      if (!first.content) ts[i + 1].hidden = ts[i + 3].hidden = true;
    }
  });
  md.renderer.rules.atlas_callout_open = (ts, i) => open(ts[i].meta.kind, ts[i].meta.title);
  md.renderer.rules.atlas_callout_close = () => '</aside>\n';
}
