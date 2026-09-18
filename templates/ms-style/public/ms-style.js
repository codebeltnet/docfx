/* Keep the full source URL while presenting the filename used by Learn. */
(function () {
  var languageNames = {
    bash: 'Bash',
    c: 'C',
    cpp: 'C++',
    cs: 'C#',
    csharp: 'C#',
    css: 'CSS',
    fsharp: 'F#',
    html: 'HTML',
    javascript: 'JavaScript',
    json: 'JSON',
    powershell: 'PowerShell',
    ps1: 'PowerShell',
    shell: 'Shell',
    text: 'Text',
    typescript: 'TypeScript',
    vb: 'Visual Basic',
    visualbasic: 'Visual Basic',
    xml: 'XML',
    yaml: 'YAML'
  };

  var affixObserver;
  var affixRootObserver;

  function shortenSourceLabels() {
    document.querySelectorAll('.facts a[href]').forEach(function (link) {
      var label = link.textContent.trim();
      var separator = Math.max(label.lastIndexOf('/'), label.lastIndexOf('\\'));
      if (separator >= 0 && separator < label.length - 1) {
        link.textContent = label.substring(separator + 1);
      }
    });
  }

  function labelCodeLanguages() {
    document.querySelectorAll('.codewrapper').forEach(function (wrapper) {
      var code = wrapper.querySelector('pre code');
      var className = code ? code.className : '';
      var match = className.match(/(?:^|\s)(?:lang|language)-([^\s]+)/i);
      var language = match ? match[1].toLowerCase() : 'code';
      var label = languageNames[language] || language.charAt(0).toUpperCase() + language.slice(1);

      wrapper.setAttribute('data-code-language', label);
    });
  }

  function getLocalizedLabel(name, fallback) {
    var meta = document.querySelector('meta[name="' + name + '"]');
    return meta ? meta.getAttribute('content') : fallback;
  }

  function isNamespacePage(article) {
    var heading = article ? article.querySelector('h1') : null;
    return !!heading && /\bNamespace\s*$/.test(heading.textContent.trim());
  }

  function convertJumpListGroup(items) {
    var table = document.createElement('table');
    var thead = document.createElement('thead');
    var tbody = document.createElement('tbody');

    table.className = 'table ms-member-table ms-jumplist-table';
    thead.innerHTML = '<tr><th scope="col">Name</th><th scope="col">Description</th></tr>';

    items.forEach(function (item) {
      var term = item.querySelector('dt');
      var description = item.querySelector('dd');
      if (!term || !description) {
        return;
      }

      var row = document.createElement('tr');
      var nameCell = document.createElement('th');
      var descriptionCell = document.createElement('td');

      nameCell.scope = 'row';
      nameCell.innerHTML = term.innerHTML;
      descriptionCell.className = 'markdown level1 summary';
      descriptionCell.innerHTML = description.innerHTML;

      row.appendChild(nameCell);
      row.appendChild(descriptionCell);
      tbody.appendChild(row);
    });

    table.appendChild(thead);
    table.appendChild(tbody);
    items[0].before(table);
    items.forEach(function (item) { item.remove(); });
  }

  function enhanceNamespacePage() {
    var article = document.querySelector('main .content article');
    if (!article || !isNamespacePage(article)) {
      return;
    }

    article.classList.add('ms-namespace-page');

    var node = article.firstElementChild;
    while (node) {
      var next = node.nextElementSibling;
      if (node.matches('h2, h3')) {
        var items = [];
        while (next && next.matches('dl.jumplist')) {
          items.push(next);
          next = next.nextElementSibling;
        }

        if (items.length) {
          convertJumpListGroup(items);
        }
      }

      node = next || node.nextElementSibling;
    }
  }

  function syncInlineAffix() {
    var article = document.querySelector('main .content article');
    var heading = article ? article.querySelector('h1') : null;
    var affix = document.getElementById('affix');
    var inlineAffix = article ? article.querySelector('.ms-inline-affix') : null;

    if (!article || !heading || !affix || !affix.querySelector('a[href]')) {
      if (inlineAffix) {
        inlineAffix.remove();
      }

      return;
    }

    if (!inlineAffix) {
      inlineAffix = document.createElement('section');
      inlineAffix.className = 'ms-inline-affix';
      inlineAffix.setAttribute('aria-label', getLocalizedLabel('loc:inThisArticle', 'In this article'));
      heading.insertAdjacentElement('afterend', inlineAffix);
    }

    if (inlineAffix.innerHTML !== affix.innerHTML) {
      inlineAffix.innerHTML = affix.innerHTML;
    }
  }

  function observeAffix() {
    var affix = document.getElementById('affix');
    if (!affix) {
      return false;
    }

    if (affixObserver) {
      return true;
    }

    var syncQueued = false;
    function requestSync() {
      if (syncQueued) {
        return;
      }

      syncQueued = true;
      window.requestAnimationFrame(function () {
        syncQueued = false;
        syncInlineAffix();
      });
    }

    affixObserver = new MutationObserver(requestSync);
    affixObserver.observe(affix, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ['class', 'aria-current']
    });

    requestSync();
    return true;
  }

  function watchForAffix() {
    if (observeAffix()) {
      return;
    }

    if (affixRootObserver || !document.body) {
      return;
    }

    affixRootObserver = new MutationObserver(function () {
      if (observeAffix()) {
        affixRootObserver.disconnect();
        affixRootObserver = null;
      }
    });

    affixRootObserver.observe(document.body, {
      childList: true,
      subtree: true
    });
  }

  function initSidebarResize() {
    var STORAGE_KEY = 'ms-sidebar-width';
    var MIN_PX = 160; /* ~10rem */

    var root = document.documentElement;
    var main = document.querySelector('body.ms-style > main.ms-has-toc');
    var tocOffcanvas = main ? main.querySelector('.toc-offcanvas') : null;

    if (!main || !tocOffcanvas) return;

    /* Restore persisted manual width */
    (function () {
      var stored = localStorage.getItem(STORAGE_KEY);
      if (!stored) return;
      var px = parseInt(stored, 10);
      if (isNaN(px)) return;
      var maxPx = Math.round(window.innerWidth * 0.38);
      if (px >= MIN_PX && px <= maxPx) {
        root.style.setProperty('--ms-sidebar-width', px + 'px');
      } else {
        localStorage.removeItem(STORAGE_KEY);
      }
    }());

    /* Inject resize handle */
    var resizer = document.createElement('div');
    resizer.className = 'ms-sidebar-resizer';
    resizer.setAttribute('aria-hidden', 'true');
    resizer.title = 'Drag to resize sidebar. Double-click to reset.';
    tocOffcanvas.appendChild(resizer);

    var startX = 0, startWidth = 0, dragging = false;

    function isMobile() {
      return window.matchMedia('(max-width: 767.98px)').matches;
    }

    function getMaxPx() {
      return Math.round(window.innerWidth * 0.38);
    }

    function clampWidth(px) {
      return Math.min(Math.max(px, MIN_PX), getMaxPx());
    }

    resizer.addEventListener('pointerdown', function (e) {
      if (isMobile()) return;
      e.preventDefault();
      resizer.setPointerCapture(e.pointerId);
      dragging = true;
      resizer.classList.add('ms-dragging');
      startX = e.clientX;
      startWidth = tocOffcanvas.getBoundingClientRect().width;
      document.body.style.userSelect = 'none';
      document.body.style.cursor = 'col-resize';
    });

    resizer.addEventListener('pointermove', function (e) {
      if (!dragging) return;
      var w = clampWidth(startWidth + e.clientX - startX);
      root.style.setProperty('--ms-sidebar-width', w + 'px');
    });

    function endDrag() {
      if (!dragging) return;
      dragging = false;
      resizer.classList.remove('ms-dragging');
      document.body.style.userSelect = '';
      document.body.style.cursor = '';
      var val = root.style.getPropertyValue('--ms-sidebar-width');
      var px = parseInt(val, 10);
      if (!isNaN(px)) localStorage.setItem(STORAGE_KEY, px);
    }

    resizer.addEventListener('pointerup', endDrag);
    resizer.addEventListener('pointercancel', endDrag);

    /* Double-click resets to automatic content-derived width */
    resizer.addEventListener('dblclick', function () {
      root.style.removeProperty('--ms-sidebar-width');
      localStorage.removeItem(STORAGE_KEY);
    });

    /* Clamp stored width when viewport is resized */
    window.addEventListener('resize', function () {
      var val = root.style.getPropertyValue('--ms-sidebar-width');
      if (!val) return;
      var px = parseInt(val, 10);
      if (isNaN(px)) return;
      var clamped = clampWidth(px);
      if (clamped !== px) root.style.setProperty('--ms-sidebar-width', clamped + 'px');
    });
  }

  function initialize() {
    shortenSourceLabels();
    labelCodeLanguages();
    enhanceNamespacePage();
    watchForAffix();
    syncInlineAffix();
    initSidebarResize();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initialize);
  } else {
    initialize();
  }
})();
