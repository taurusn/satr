(() => {
  "use strict";

  const state = {
    headings: [],
    mermaidErrors: 0
  };

  const decodeBase64 = (value) => {
    const bytes = Uint8Array.from(atob(value), (character) => character.charCodeAt(0));
    return new TextDecoder("utf-8").decode(bytes);
  };

  const escapeHTML = (value) => String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");

  const stripFrontmatter = (markdown) => markdown.replace(/^\uFEFF?---[ \t]*\r?\n[\s\S]*?\r?\n---[ \t]*(?:\r?\n|$)/, "");

  const slugify = (text) => text
    .normalize("NFKD")
    .toLowerCase()
    .trim()
    .replace(/[^\p{Letter}\p{Number}\s-]/gu, "")
    .replace(/\s+/g, "-")
    .replace(/-+/g, "-") || "section";

  const wikiLinkExtension = {
    name: "wikilink",
    level: "inline",
    start(source) {
      const index = source.indexOf("[[");
      return index < 0 ? undefined : index;
    },
    tokenizer(source) {
      const match = /^\[\[([^\]|]+?)(?:\|([^\]]+?))?\]\]/.exec(source);
      if (!match) return undefined;
      return {
        type: "wikilink",
        raw: match[0],
        target: match[1].trim(),
        label: (match[2] || match[1]).trim()
      };
    },
    renderer(token) {
      const target = encodeURIComponent(token.target);
      return `<a class="wikilink" href="satr-wiki:${target}">${escapeHTML(token.label)}</a>`;
    }
  };

  const markDirection = (root) => {
    root.querySelectorAll("p, li, blockquote, td, th, h1, h2, h3, h4, h5, h6").forEach((element) => {
      element.setAttribute("dir", "auto");
    });
  };

  const assignHeadingIDs = (root) => {
    const seen = new Map();
    root.querySelectorAll("h1, h2, h3, h4, h5, h6").forEach((heading) => {
      const base = slugify(heading.textContent || "section");
      const count = seen.get(base) || 0;
      seen.set(base, count + 1);
      heading.id = count === 0 ? base : `${base}-${count + 1}`;
    });
  };

  const prepareLinks = (root) => {
    root.querySelectorAll("a[href]").forEach((link) => {
      link.setAttribute("rel", "noopener noreferrer");
      const href = link.getAttribute("href") || "";
      if (/^https?:/i.test(href)) link.setAttribute("title", "Open in browser");
    });
  };

  const prepareLocalMedia = (root) => {
    root.querySelectorAll("img[src], video[src], audio[src], source[src]").forEach((element) => {
      const source = element.getAttribute("src") || "";
      if (!source || /^(?:data:|https?:|satr-local:)/i.test(source)) return;
      element.setAttribute("src", `satr-local://asset?path=${encodeURIComponent(source)}`);
    });
  };

  const prepareTasks = (root) => {
    root.querySelectorAll('input[type="checkbox"]').forEach((checkbox) => {
      checkbox.disabled = true;
      checkbox.setAttribute("aria-label", checkbox.checked ? "Completed task" : "Incomplete task");
    });
  };

  const renderMermaid = async (root) => {
    const blocks = [...root.querySelectorAll("pre > code.language-mermaid, pre > code.lang-mermaid")];
    if (blocks.length === 0) return;

    const dark = window.matchMedia("(prefers-color-scheme: dark)").matches;
    mermaid.initialize({
      startOnLoad: false,
      securityLevel: "strict",
      theme: dark ? "dark" : "base",
      fontFamily: "-apple-system, BlinkMacSystemFont, sans-serif",
      themeVariables: dark
        ? { primaryColor: "#263a30", primaryTextColor: "#ecefe9", primaryBorderColor: "#79aa91", lineColor: "#8f9a91", secondaryColor: "#252a24", tertiaryColor: "#20241f" }
        : { primaryColor: "#dfe9e3", primaryTextColor: "#242723", primaryBorderColor: "#3d6756", lineColor: "#68766d", secondaryColor: "#ecefea", tertiaryColor: "#f4f5f2" }
    });

    const nodes = blocks.map((code, index) => {
      const pre = code.parentElement;
      const shell = document.createElement("div");
      shell.className = "mermaid-shell";
      const diagram = document.createElement("div");
      diagram.className = "mermaid";
      diagram.id = `satr-mermaid-${index}`;
      diagram.textContent = code.textContent || "";
      shell.appendChild(diagram);
      pre.replaceWith(shell);
      return diagram;
    });

    try {
      await mermaid.run({ nodes, suppressErrors: false });
    } catch (error) {
      state.mermaidErrors += 1;
      nodes.filter((node) => !node.querySelector("svg")).forEach((node) => {
        const source = node.textContent || "";
        node.className = "mermaid-error";
        node.textContent = `Diagram could not be rendered.\n\n${source}`;
      });
    }
  };

  const buildDocumentThread = (root) => {
    const thread = document.getElementById("document-thread");
    const headings = [...root.querySelectorAll("h2, h3")];
    state.headings = headings;

    if (headings.length < 2) {
      thread.hidden = true;
      return;
    }

    thread.hidden = false;
    thread.replaceChildren();

    const line = document.createElement("div");
    line.className = "thread-line";
    const progress = document.createElement("div");
    progress.className = "thread-progress";
    thread.append(line, progress);

    headings.forEach((heading, index) => {
      const button = document.createElement("button");
      button.className = "thread-node";
      button.dataset.index = String(index);
      button.dataset.level = heading.tagName.slice(1);
      button.title = heading.textContent || `Section ${index + 1}`;
      button.setAttribute("aria-label", `Go to ${button.title}`);
      button.addEventListener("click", () => heading.scrollIntoView({ behavior: "smooth", block: "start" }));
      thread.appendChild(button);
    });

    const update = () => {
      const maxScroll = Math.max(1, document.documentElement.scrollHeight - window.innerHeight);
      const scrollFraction = Math.min(1, Math.max(0, window.scrollY / maxScroll));
      progress.style.height = `${scrollFraction * 100}%`;

      const nodes = [...thread.querySelectorAll(".thread-node")];
      nodes.forEach((node, index) => {
        const headingScrollPosition = Math.max(0, headings[index].offsetTop - 44);
        const position = Math.min(1, headingScrollPosition / maxScroll);
        node.style.top = `${position * 100}%`;
      });

      let activeIndex = 0;
      headings.forEach((heading, index) => {
        if (heading.getBoundingClientRect().top <= Math.min(180, window.innerHeight * 0.3)) activeIndex = index;
      });
      nodes.forEach((node, index) => {
        node.classList.toggle("is-active", index === activeIndex);
        node.classList.toggle("is-past", index < activeIndex);
      });
    };

    window.addEventListener("scroll", update, { passive: true });
    window.addEventListener("resize", update, { passive: true });
    update();
  };

  window.satrScrollToHeading = (heading) => {
    const normalized = slugify(heading);
    const target = document.getElementById(normalized)
      || [...document.querySelectorAll("h1, h2, h3, h4, h5, h6")].find((node) => (node.textContent || "").trim() === heading.trim());
    target?.scrollIntoView({ behavior: "smooth", block: "start" });
  };

  const postStatus = (root) => {
    const title = root.querySelector("h1")?.textContent?.trim() || decodeBase64(window.SATR_DOCUMENT.fileNameBase64).replace(/\.[^.]+$/, "");
    window.webkit?.messageHandlers?.satr?.postMessage({
      title,
      headings: state.headings.length,
      mermaidErrors: state.mermaidErrors
    });
  };

  const render = async () => {
    const root = document.getElementById("document");
    try {
      const fileName = decodeBase64(window.SATR_DOCUMENT.fileNameBase64);
      const source = decodeBase64(window.SATR_DOCUMENT.markdownBase64);

      if (/\.txt$/i.test(fileName)) {
        root.innerHTML = `<pre class="plain-text" dir="auto">${escapeHTML(source)}</pre>`;
        state.headings = [];
        buildDocumentThread(root);
        postStatus(root);
        window.scrollTo({ top: 0, left: 0, behavior: "instant" });
        document.body.dataset.rendered = "true";
        return;
      }

      const markdown = stripFrontmatter(source);
      marked.use({ extensions: [wikiLinkExtension] });
      marked.setOptions({ gfm: true, breaks: false });

      const dirtyHTML = marked.parse(markdown);
      root.innerHTML = DOMPurify.sanitize(dirtyHTML, {
        USE_PROFILES: { html: true, svg: true, svgFilters: true },
        ALLOW_UNKNOWN_PROTOCOLS: true,
        ADD_ATTR: ["target", "checked", "disabled"]
      });

      assignHeadingIDs(root);
      markDirection(root);
      prepareLinks(root);
      prepareLocalMedia(root);
      prepareTasks(root);
      await renderMermaid(root);
      buildDocumentThread(root);
      postStatus(root);
      window.scrollTo({ top: 0, left: 0, behavior: "instant" });
      requestAnimationFrame(() => window.scrollTo({ top: 0, left: 0, behavior: "instant" }));
      document.body.dataset.rendered = "true";
    } catch (error) {
      root.innerHTML = `<h1>This document could not be rendered</h1><p>${escapeHTML(error?.message || String(error))}</p>`;
      document.body.dataset.rendered = "error";
    }
  };

  render();
})();
