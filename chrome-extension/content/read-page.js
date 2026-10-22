// Wisp Tabs — reads a page's text, selection and headings (phase 02).
//
// Why text and not a screenshot: a screenshot costs the local model ~4s of
// vision encoding, and it only shows what's on screen. The page's own text is
// cheaper, complete (it reaches below the fold and into background tabs) and
// exact (prices and names aren't read back from pixels).
//
// Injected on demand by handlers/page-reading.js with
// `chrome.scripting.executeScript({files: ["content/read-page.js"]})`, which
// runs it as a classic script in the extension's isolated world. It only
// defines `globalThis.wispPageReader`; the handler then calls one of its
// functions with a second `executeScript({func})`. Nothing runs on its own and
// nothing stays listening.
//
// Every function takes the document to read as a parameter, so the tests can
// run them against fixture HTML with no browser.
//
// Never reads secrets (contracts.md §6): form controls are skipped entirely
// (their values are never read), and so is anything inside
// `[data-wisp-ignore]`. A selection inside either reads as no selection.
//
// Written from scratch, Readability-style: keep the main content, drop the
// page furniture (navigation, sidebars, footers, cookie banners).

(() => {
  // Mirrors MAXIMUM_TEXT_FIELD_CHARACTERS in lib/limits.js. A classic content
  // script can't import modules, and capping here means a huge page never
  // crosses into the service worker as one giant string.
  const MAXIMUM_TEXT_CHARACTERS = 20000;
  const MAXIMUM_OUTLINE_HEADINGS = 500;
  const MAXIMUM_HEADING_CHARACTERS = 300;
  // Bounds the walk on pathological pages (infinite feeds, generated tables).
  const MAXIMUM_VISITED_ELEMENTS = 200000;
  const SELECTION_CONTEXT_CHARACTERS = 300;

  // Never part of the readable text, whatever they contain.
  const ALWAYS_SKIPPED_TAGS = new Set([
    "script", "style", "noscript", "template", "svg", "canvas", "iframe", "frame", "object",
    "embed", "video", "audio", "map", "head", "meta", "link", "title",
    // Form controls: skipped so a field's value is never read, password or not.
    // Not <form> itself: some sites wrap the whole page in one.
    "input", "textarea", "select", "option", "button", "datalist", "output",
    // Page furniture.
    "nav", "aside", "footer", "dialog",
  ]);

  const SKIPPED_ROLES = new Set([
    "navigation", "complementary", "contentinfo", "search", "banner", "dialog", "alertdialog",
    "menu", "menubar", "toolbar", "tablist",
  ]);

  // id/class words that mark furniture rather than content. Matched as whole
  // words between - _ and spaces, so "ads" never matches "headset". Not
  // "comment": on a forum or Hacker News the comments are the content.
  const FURNITURE_NAME_PATTERN =
    /(^|[\s_-])(cookie|cookies|consent|gdpr|newsletter|subscribe|share|sharing|social|related|recommended|advert|advertisement|ads?|promo|sidebar|breadcrumbs?|skip-link|skiplink|navbar|menu|popup|modal)($|[\s_-])/i;

  // Elements whose end is the end of a line of text.
  const BLOCK_TAGS = new Set([
    "address", "article", "blockquote", "dd", "details", "div", "dl", "dt", "fieldset",
    "figcaption", "figure", "header", "hgroup", "hr", "li", "main", "ol", "p", "pre",
    "section", "summary", "table", "tbody", "thead", "tfoot", "tr", "ul", "caption",
  ]);

  const HEADING_LEVEL_BY_TAG = { h1: 1, h2: 2, h3: 3, h4: 4, h5: 5, h6: 6 };

  // MARK: - What counts as readable

  function tagNameOf(element) {
    return (element.tagName || "").toLowerCase();
  }

  function isInsideIgnoredRegion(node) {
    const element = node && node.nodeType === 1 ? node : node?.parentElement ?? node?.parentNode;
    return Boolean(element && typeof element.closest === "function" && element.closest("[data-wisp-ignore]"));
  }

  // Secret fields by contracts §6, for the selection check (the walk skips
  // every form control anyway).
  function isSecretField(element) {
    if (!element || element.nodeType !== 1) return false;
    const tagName = tagNameOf(element);
    if (tagName !== "input" && tagName !== "textarea") return false;
    if ((element.getAttribute("type") || "").toLowerCase() === "password") return true;
    const autocompleteTokens = (element.getAttribute("autocomplete") || "").toLowerCase().split(/\s+/);
    return autocompleteTokens.some(
      (token) =>
        token.startsWith("cc-") || token === "one-time-code" || token === "current-password" || token === "new-password"
    );
  }

  function isHidden(element) {
    if (element.hasAttribute("hidden")) return true;
    if (element.getAttribute("aria-hidden") === "true") return true;
    const inlineStyle = (element.getAttribute("style") || "").replace(/\s+/g, "").toLowerCase();
    if (inlineStyle.includes("display:none") || inlineStyle.includes("visibility:hidden")) return true;
    // Chrome's own answer, which also sees stylesheets. Absent in the tests'
    // DOM, where the attribute checks above stand in for it.
    if (typeof element.checkVisibility === "function") {
      return !element.checkVisibility({ visibilityProperty: true });
    }
    return false;
  }

  function looksLikeFurniture(element) {
    const role = (element.getAttribute("role") || "").toLowerCase();
    if (SKIPPED_ROLES.has(role)) return true;
    const tagName = tagNameOf(element);
    // A page-level header is the site banner; a header inside the article is
    // where its title and byline live.
    if (tagName === "header" && !element.closest("article, main, [role=main]")) return true;
    const nameText = `${element.getAttribute("id") || ""} ${element.getAttribute("class") || ""}`;
    return FURNITURE_NAME_PATTERN.test(nameText);
  }

  // Whether the walk should leave this element (and everything in it) out.
  // `rootElement` itself is never furniture: it was chosen as the content.
  function shouldSkipElement(element, rootElement) {
    if (ALWAYS_SKIPPED_TAGS.has(tagNameOf(element))) return true;
    if (element.hasAttribute("data-wisp-ignore")) return true;
    if (isHidden(element)) return true;
    if (element !== rootElement && looksLikeFurniture(element)) return true;
    return false;
  }

  // MARK: - Choosing the main content

  function roughTextLength(element) {
    return (element?.textContent || "").replace(/\s+/g, " ").trim().length;
  }

  // Prefers <main> / [role=main], or a single dominant <article>, over the
  // whole body, so a docs sidebar or a news site's "more stories" don't end up
  // in the text.
  function chooseContentRoot(documentToRead) {
    const body = documentToRead.body || documentToRead.documentElement;
    const mainElement = documentToRead.querySelector("main, [role=main]");
    const articleElements = [...documentToRead.querySelectorAll("article")];
    const scope = mainElement || body;
    const scopeTextLength = roughTextLength(scope);

    // One article that holds most of the scope's text is the content. Several
    // similar articles (a feed) are not: keep the whole scope.
    const articlesInScope = articleElements.filter((article) => scope.contains(article));
    if (articlesInScope.length > 0) {
      const longestArticle = articlesInScope.reduce((longest, article) =>
        roughTextLength(article) > roughTextLength(longest) ? article : longest
      );
      const longestArticleLength = roughTextLength(longestArticle);
      const minimumShareOfScope = mainElement ? 0.5 : 0.35;
      if (longestArticleLength > 0 && longestArticleLength >= scopeTextLength * minimumShareOfScope) {
        return longestArticle;
      }
    }
    return scope;
  }

  // MARK: - Turning elements into lines

  function collapseWhitespace(text) {
    return text.replace(/[\s ]+/g, " ");
  }

  // Lines of text, with headings as "#" lines, list items as "- " lines and
  // table rows as cells joined by " | ".
  function createLineBuilder() {
    const lines = [];
    let currentLine = "";
    let pendingPrefix = "";

    function flushLine() {
      const lineText = collapseWhitespace(currentLine).trim();
      if (lineText) {
        lines.push(pendingPrefix + lineText);
        pendingPrefix = "";
      }
      currentLine = "";
    }

    return {
      lines,
      appendInline(text) {
        currentLine += text;
      },
      flushLine,
      // The prefix goes on the next non-empty line (a list item's text).
      startLineWithPrefix(prefix) {
        flushLine();
        pendingPrefix = prefix;
      },
      pushLine(lineText) {
        flushLine();
        pendingPrefix = "";
        if (lineText) lines.push(lineText);
      },
      pushBlankLine() {
        flushLine();
        if (lines.length > 0 && lines[lines.length - 1] !== "") lines.push("");
      },
    };
  }

  function headingLevelOf(element) {
    const tagLevel = HEADING_LEVEL_BY_TAG[tagNameOf(element)];
    if (tagLevel) return tagLevel;
    if ((element.getAttribute("role") || "").toLowerCase() === "heading") {
      const ariaLevel = parseInt(element.getAttribute("aria-level") || "2", 10);
      return Math.min(Math.max(Number.isFinite(ariaLevel) ? ariaLevel : 2, 1), 6);
    }
    return 0;
  }

  // Walks `rootElement` into `lineBuilder`. `walkState` counts visited
  // elements so a pathological page can't hang the tab.
  function walkElement(element, rootElement, lineBuilder, walkState, listDepth) {
    for (const childNode of element.childNodes) {
      if (walkState.visitedElementCount >= MAXIMUM_VISITED_ELEMENTS) {
        walkState.stoppedEarly = true;
        return;
      }
      if (childNode.nodeType === 3) {
        lineBuilder.appendInline(childNode.nodeValue || "");
        continue;
      }
      if (childNode.nodeType !== 1) continue;

      walkState.visitedElementCount += 1;
      const childElement = childNode;
      if (shouldSkipElement(childElement, rootElement)) continue;
      const tagName = tagNameOf(childElement);

      const headingLevel = headingLevelOf(childElement);
      if (headingLevel > 0) {
        const headingText = readableInlineText(childElement, rootElement);
        if (headingText) {
          lineBuilder.pushBlankLine();
          lineBuilder.pushLine(`${"#".repeat(headingLevel)} ${headingText}`);
        }
        continue;
      }

      if (tagName === "br") {
        lineBuilder.flushLine();
        continue;
      }

      if (tagName === "li") {
        lineBuilder.startLineWithPrefix(`${"  ".repeat(Math.max(listDepth - 1, 0))}- `);
        walkElement(childElement, rootElement, lineBuilder, walkState, listDepth);
        lineBuilder.flushLine();
        continue;
      }

      if (tagName === "tr") {
        const cellTexts = [...childElement.children]
          .filter((cell) => ["td", "th"].includes(tagNameOf(cell)) && !shouldSkipElement(cell, rootElement))
          .map((cell) => readableInlineText(cell, rootElement));
        if (cellTexts.some((cellText) => cellText.length > 0)) {
          lineBuilder.pushLine(cellTexts.join(" | "));
        }
        continue;
      }

      if (tagName === "pre") {
        lineBuilder.flushLine();
        const preformattedText = readablePreformattedText(childElement, rootElement);
        for (const preformattedLine of preformattedText.split("\n")) {
          if (preformattedLine.trim()) lineBuilder.pushLine(preformattedLine.replace(/\s+$/, ""));
        }
        continue;
      }

      const isBlock = BLOCK_TAGS.has(tagName);
      const nextListDepth = tagName === "ul" || tagName === "ol" ? listDepth + 1 : listDepth;
      if (isBlock) lineBuilder.flushLine();
      if (tagName === "p" || tagName === "blockquote") lineBuilder.pushBlankLine();
      walkElement(childElement, rootElement, lineBuilder, walkState, nextListDepth);
      if (isBlock) lineBuilder.flushLine();
    }
  }

  // An element's text on one line, honouring the same skips as the walk.
  function readableInlineText(element, rootElement) {
    const lineBuilder = createLineBuilder();
    walkElement(element, rootElement, lineBuilder, { visitedElementCount: 0, stoppedEarly: false }, 0);
    lineBuilder.flushLine();
    return collapseWhitespace(lineBuilder.lines.filter(Boolean).join(" ")).trim();
  }

  // A <pre>'s text with its line breaks kept, skipping ignored regions.
  function readablePreformattedText(element, rootElement) {
    let text = "";
    for (const childNode of element.childNodes) {
      if (childNode.nodeType === 3) {
        text += childNode.nodeValue || "";
      } else if (childNode.nodeType === 1 && !shouldSkipElement(childNode, rootElement)) {
        text += tagNameOf(childNode) === "br" ? "\n" : readablePreformattedText(childNode, rootElement);
      }
    }
    return text;
  }

  function readableTextOf(rootElement) {
    const lineBuilder = createLineBuilder();
    const walkState = { visitedElementCount: 0, stoppedEarly: false };
    walkElement(rootElement, rootElement, lineBuilder, walkState, 0);
    lineBuilder.flushLine();
    while (lineBuilder.lines.length > 0 && lineBuilder.lines[lineBuilder.lines.length - 1] === "") {
      lineBuilder.lines.pop();
    }
    return { text: lineBuilder.lines.join("\n"), stoppedEarly: walkState.stoppedEarly };
  }

  function capText(text, maximumCharacters) {
    if (text.length <= maximumCharacters) return { text, truncated: false };
    let cutIndex = maximumCharacters;
    const lastKeptCharacterCode = text.charCodeAt(cutIndex - 1);
    if (lastKeptCharacterCode >= 0xd800 && lastKeptCharacterCode <= 0xdbff) cutIndex -= 1;
    return { text: text.slice(0, cutIndex), truncated: true };
  }

  function countWords(text) {
    const words = text.match(/[^\s#|-][^\s]*/g);
    return words ? words.length : 0;
  }

  // MARK: - Metadata

  function metaContent(documentToRead, selector) {
    const content = documentToRead.querySelector(selector)?.getAttribute("content");
    return content ? collapseWhitespace(content).trim() : "";
  }

  // `datePublished` anywhere in the page's JSON-LD (it is often nested in a
  // @graph). Only parsed, never run.
  function jsonLinkedDataPublishedDate(documentToRead) {
    for (const scriptElement of documentToRead.querySelectorAll('script[type="application/ld+json"]')) {
      let parsedData;
      try {
        parsedData = JSON.parse(scriptElement.textContent || "");
      } catch (error) {
        continue;
      }
      const pendingValues = [parsedData];
      let inspectedValueCount = 0;
      while (pendingValues.length > 0 && inspectedValueCount < 500) {
        const value = pendingValues.shift();
        inspectedValueCount += 1;
        if (Array.isArray(value)) {
          pendingValues.push(...value);
        } else if (value && typeof value === "object") {
          if (typeof value.datePublished === "string" && value.datePublished.trim()) {
            return value.datePublished.trim();
          }
          pendingValues.push(...Object.values(value));
        }
      }
    }
    return "";
  }

  function publishedDateOf(documentToRead) {
    return (
      metaContent(documentToRead, 'meta[property="article:published_time"]') ||
      metaContent(documentToRead, 'meta[name="article:published_time"]') ||
      metaContent(documentToRead, 'meta[itemprop="datePublished"]') ||
      metaContent(documentToRead, 'meta[name="date"]') ||
      metaContent(documentToRead, 'meta[name="pubdate"]') ||
      metaContent(documentToRead, 'meta[name="dc.date"]') ||
      documentToRead.querySelector("time[itemprop=datePublished][datetime]")?.getAttribute("datetime")?.trim() ||
      jsonLinkedDataPublishedDate(documentToRead) ||
      documentToRead.querySelector("article time[datetime]")?.getAttribute("datetime")?.trim() ||
      ""
    );
  }

  function canonicalURLOf(documentToRead) {
    const canonicalLink = documentToRead.querySelector('link[rel="canonical"][href]');
    if (canonicalLink) {
      // `.href` resolves a relative link against the page in a browser.
      return (canonicalLink.href || canonicalLink.getAttribute("href") || "").trim();
    }
    return metaContent(documentToRead, 'meta[property="og:url"]');
  }

  function pageTitleOf(documentToRead) {
    const documentTitle = collapseWhitespace(documentToRead.title || "").trim();
    return documentTitle || metaContent(documentToRead, 'meta[property="og:title"]');
  }

  // MARK: - The three readings

  function readPageText(documentToRead, options = {}) {
    const requestedMaximum = Number.isInteger(options.maximumCharacters) ? options.maximumCharacters : MAXIMUM_TEXT_CHARACTERS;
    const maximumCharacters = Math.min(Math.max(requestedMaximum, 1), MAXIMUM_TEXT_CHARACTERS);
    const contentRoot = chooseContentRoot(documentToRead);
    const { text: fullText, stoppedEarly } = contentRoot ? readableTextOf(contentRoot) : { text: "", stoppedEarly: false };
    const cappedText = capText(fullText, maximumCharacters);
    return {
      title: pageTitleOf(documentToRead),
      canonicalUrl: canonicalURLOf(documentToRead),
      lang: (documentToRead.documentElement?.getAttribute("lang") || "").trim(),
      description:
        metaContent(documentToRead, 'meta[name="description"]') ||
        metaContent(documentToRead, 'meta[property="og:description"]'),
      publishedDate: publishedDateOf(documentToRead),
      text: cappedText.text,
      wordCount: countWords(fullText),
      characterCount: fullText.length,
      truncated: cappedText.truncated || stoppedEarly,
    };
  }

  function readPageOutline(documentToRead) {
    const contentRoot = chooseContentRoot(documentToRead);
    const headings = [];
    let truncated = false;
    if (contentRoot) {
      for (const candidateElement of contentRoot.querySelectorAll("h1, h2, h3, h4, h5, h6, [role=heading]")) {
        if (hasSkippedAncestor(candidateElement, contentRoot)) continue;
        const headingText = readableInlineText(candidateElement, contentRoot);
        if (!headingText) continue;
        if (headings.length >= MAXIMUM_OUTLINE_HEADINGS) {
          truncated = true;
          break;
        }
        headings.push({
          level: headingLevelOf(candidateElement) || 2,
          text: capText(headingText, MAXIMUM_HEADING_CHARACTERS).text,
        });
      }
    }
    return { title: pageTitleOf(documentToRead), headings, truncated };
  }

  function hasSkippedAncestor(element, rootElement) {
    for (let current = element; current && current !== rootElement; current = current.parentElement) {
      if (shouldSkipElement(current, rootElement)) return true;
    }
    return false;
  }

  // The selected text plus ~300 characters either side, read with the same
  // skips as the page text, so the context never carries a secret either.
  function readSelection(documentToRead, options = {}) {
    const contextCharacters = Number.isInteger(options.contextCharacters)
      ? Math.min(Math.max(options.contextCharacters, 0), 2000)
      : SELECTION_CONTEXT_CHARACTERS;
    const emptySelection = {
      title: pageTitleOf(documentToRead),
      hasSelection: false,
      selectedText: "",
      contextBefore: "",
      contextAfter: "",
      truncated: false,
    };

    const activeElement = documentToRead.activeElement;
    if (isSecretField(activeElement) || isInsideIgnoredRegion(activeElement)) {
      return emptySelection;
    }

    // Text selected inside an ordinary text field isn't part of the document
    // selection, so it's read from the field.
    const activeTagName = activeElement ? tagNameOf(activeElement) : "";
    if (
      (activeTagName === "textarea" || activeTagName === "input") &&
      typeof activeElement.selectionStart === "number" &&
      activeElement.selectionEnd > activeElement.selectionStart
    ) {
      const fieldValue = String(activeElement.value || "");
      const selectedFieldText = fieldValue.slice(activeElement.selectionStart, activeElement.selectionEnd).trim();
      if (!selectedFieldText) return emptySelection;
      const cappedFieldText = capText(selectedFieldText, MAXIMUM_TEXT_CHARACTERS);
      return { ...emptySelection, hasSelection: true, selectedText: cappedFieldText.text, truncated: cappedFieldText.truncated };
    }

    const selection =
      typeof documentToRead.getSelection === "function"
        ? documentToRead.getSelection()
        : documentToRead.defaultView?.getSelection?.();
    if (!selection || !selection.rangeCount) return emptySelection;
    if (isInsideIgnoredRegion(selection.anchorNode) || isInsideIgnoredRegion(selection.focusNode)) {
      return emptySelection;
    }

    const range = selection.getRangeAt(0);
    let commonAncestor = range.commonAncestorContainer;
    if (commonAncestor && commonAncestor.nodeType !== 1) commonAncestor = commonAncestor.parentElement;
    if (!commonAncestor || isInsideIgnoredRegion(commonAncestor)) return emptySelection;

    // A selection that spans an ignored region or a secret field drops out
    // whole rather than being half-read.
    if (commonAncestor.querySelector?.("[data-wisp-ignore], input[type=password]")) {
      return emptySelection;
    }

    const selectedText = collapseWhitespace(selection.toString() || "").trim();
    if (!selectedText) return emptySelection;
    const cappedSelection = capText(selectedText, MAXIMUM_TEXT_CHARACTERS);

    // Context: climb to an ancestor with enough text around the selection,
    // then find the selection in that ancestor's readable text.
    let contextElement = commonAncestor;
    const wantedContextLength = selectedText.length + contextCharacters * 2;
    for (let climbCount = 0; climbCount < 8; climbCount += 1) {
      const parentElement = contextElement.parentElement;
      if (roughTextLength(contextElement) >= wantedContextLength || !parentElement) break;
      if (tagNameOf(parentElement) === "html") break;
      contextElement = parentElement;
    }
    const contextText = collapseWhitespace(readableTextOf(contextElement).text);
    const selectionIndex = contextText.indexOf(selectedText);
    let contextBefore = "";
    let contextAfter = "";
    if (selectionIndex >= 0) {
      contextBefore = contextText.slice(Math.max(0, selectionIndex - contextCharacters), selectionIndex).trimStart();
      contextAfter = contextText
        .slice(selectionIndex + selectedText.length, selectionIndex + selectedText.length + contextCharacters)
        .trimEnd();
    }

    return {
      ...emptySelection,
      hasSelection: true,
      selectedText: cappedSelection.text,
      contextBefore,
      contextAfter,
      truncated: cappedSelection.truncated,
    };
  }

  globalThis.wispPageReader = { readPageText, readPageOutline, readSelection };
})();
