(() => {
    const meta = name => document.querySelector(`meta[name="docfx:${name}"]`);
    const apiMeta = meta('framework-api');
    if (!apiMeta?.content) return;
    const api = apiMeta.content;
    const current = new URL(location.href);
    const isApiPage = current.pathname.startsWith(api);
    // Match NGINX's $arg_view lookup, which is case-insensitive for the argument name.
    const view = isApiPage ? current.search.match(/(?:^\?|&)view=([^&]*)/i)?.[1] : undefined;

    let manifest = null;
    const manifestReady = fetch('/framework-views.json')
        .then(response => (response.ok ? response.json() : null))
        .then(data => {
            if (data?.schemaVersion === 1 && data.apiPath === api) {
                manifest = data;
            }
            return manifest;
        })
        .catch(() => null);

    const searchRoot = view ? `/_framework-search/${meta('framework-directory').content}/` : null;

    if (view) {
        const toc = meta('tocrel');
        if (toc?.content) {
            const url = new URL(toc.content, current);
            if (url.origin === current.origin && url.pathname.startsWith(api)) {
                url.pathname = url.pathname.replace(/\.html$/i, '.json');
                setView(url, view);
                toc.content = url.href;
            }
        }

        const search = meta('rel');
        if (search) search.content = searchRoot;
    }

    function setView(url, selected) {
        for (const key of [...url.searchParams.keys()]) {
            if (key !== 'view' && key.toLowerCase() === 'view') url.searchParams.delete(key);
        }
        url.searchParams.set('view', selected);
    }

    function getUrlView(url) {
        return url.search.match(/(?:^\?|&)view=([^&]*)/i)?.[1] || null;
    }

    function isPagePath(pathname) {
        return pathname.endsWith('.html') || pathname.endsWith('/');
    }

    function resolveAvailableViews(pathname) {
        const availability = manifest?.availability;
        if (!availability?.pages || !availability?.sets || !pathname.startsWith(api)) return null;
        let relative = pathname.slice(api.length);
        try {
            relative = decodeURIComponent(relative);
        } catch {
            return null;
        }
        const lookup = relative === '' || relative.endsWith('/') ? relative + 'index.html' : relative;
        const setIndex = availability.pages[lookup];
        if (typeof setIndex !== 'number') return null;
        return availability.sets[setIndex] ?? null;
    }

    function resolveView(pathname, preferred) {
        const available = resolveAvailableViews(pathname);
        if (!available?.length) return null;
        if (preferred && available.includes(preferred)) return preferred;
        return available[0];
    }

    function preserveView(anchor) {
        const href = anchor.getAttribute('href');
        if (!href || href.startsWith('#')) return;
        let url;
        try {
            url = new URL(href, current);
        } catch {
            return;
        }
        if (url.origin !== current.origin) return;
        const fromSearch = Boolean(searchRoot && url.pathname.startsWith(searchRoot));
        if (fromSearch) url.pathname = '/' + url.pathname.slice(searchRoot.length);
        const isApi = url.pathname.startsWith(api);

        let targetView = null;
        let shouldRewrite = fromSearch;

        if (isApi && isPagePath(url.pathname)) {
            if (view) {
                targetView = resolveView(url.pathname, view) ?? view;
                setView(url, targetView);
                shouldRewrite = true;
            } else if (manifest) {
                const order = manifest.viewOrder ?? Object.keys(manifest.views);
                const explicit = getUrlView(url);
                if (!explicit || order.includes(explicit)) {
                    const preferred = explicit || manifest.defaultView;
                    const resolved = resolveView(url.pathname, preferred);
                    if (resolved && resolved !== preferred) {
                        targetView = resolved;
                        setView(url, resolved);
                        shouldRewrite = true;
                    }
                }
            }
        }

        if (shouldRewrite) {
            const canonical = url.pathname + url.search + url.hash;
            if (canonical !== href) anchor.setAttribute('href', canonical);
            if (fromSearch && anchor.matches('#search-results .item-title > a')) {
                const displayView = targetView ?? view;
                anchor.dataset.frameworkUrl = url.pathname + (isApi && displayView ? `?view=${encodeURIComponent(displayView)}` : '') + url.hash;
            }
        }
    }

    function updateLinks(node) {
        if (node instanceof HTMLAnchorElement) preserveView(node);
        node.querySelectorAll?.('a[href]').forEach(preserveView);
    }

    // DocFX renders the navbar, TOC, breadcrumbs, prev/next and search results after the HTML loads.
    // Observe href changes too because its renderer reuses links on search and TOC updates.
    new MutationObserver(records => {
        for (const record of records) {
            if (record.target instanceof HTMLAnchorElement) preserveView(record.target);
            for (const node of record.addedNodes) updateLinks(node);
        }
    }).observe(document.documentElement, {
        subtree: true, childList: true, attributes: true, attributeFilter: ['href']
    });
    document.addEventListener('DOMContentLoaded', () => {
        updateLinks(document);
        if (isApiPage) initializeSelector();
    });
    manifestReady.then(data => {
        if (data) updateLinks(document);
    });

    function frameworkName(entry) {
        const framework = /^net([1-4])(\d)(\d*)$/.exec(entry.tfm);
        if (framework) return `.NET Framework ${framework.slice(1).filter(Boolean).join('.')}`;

        const match = /^(netstandard|netcoreapp|net)(\d+)\.(\d+)$/.exec(entry.tfm);
        if (!match) return entry.tfm;
        const product = { netstandard: '.NET Standard', netcoreapp: '.NET Core', net: '.NET' }[match[1]];
        const version = match[1] === 'net' && match[3] === '0' ? match[2] : `${match[2]}.${match[3]}`;
        return `${product} ${version}`;
    }

    function findAnchor(fragment) {
        if (!fragment) return null;
        const anchor = document.getElementById(fragment);
        if (anchor) return anchor;
        try {
            return document.getElementById(decodeURIComponent(fragment));
        } catch {
            return null;
        }
    }

    async function initializeSelector() {
        const container = document.getElementById('framework-view');
        const article = document.querySelector('article[data-uid]');
        if (!container || !article?.dataset.uid) return;

        const loaded = await manifestReady;
        if (!loaded) return;

        const displayed = view || loaded.defaultView;
        const order = loaded.viewOrder ?? Object.keys(loaded.views);
        if (order.length < 2 || !order.includes(displayed)) return;

        const select = document.getElementById('framework-view-select');
        const status = document.getElementById('framework-view-status');
        for (const id of order) select.add(new Option(frameworkName(loaded.views[id]), id));
        select.value = displayed;
        container.hidden = false;

        const noticeKey = 'docfx:framework-fallback';
        try {
            const notice = JSON.parse(sessionStorage.getItem(noticeKey));
            if (notice?.url === location.href && order.includes(notice.requested)) {
                sessionStorage.removeItem(noticeKey);
                showFallback(notice.requested, displayed);
            }
        } catch {
            // The selector also works when browser storage is unavailable.
        }

        function showFallback(requested, selected) {
            status.textContent = `This API is not documented for ${frameworkName(loaded.views[requested])}. Showing ${frameworkName(loaded.views[selected])}.`;
        }

        select.addEventListener('change', async () => {
            const requested = select.value;
            select.value = displayed;
            if (requested === displayed) return;
            select.disabled = true;
            status.textContent = '';
            try {
                const page = new URL(location.href);
                const anchor = findAnchor(page.hash.slice(1));
                const uid = anchor?.dataset.uid || article.dataset.uid;
                const candidates = new Set([requested, ...order]);
                for (const candidate of candidates) {
                    const target = await findUid(loaded.views[candidate], uid);
                    if (!target) continue;

                    if (candidate === displayed) {
                        if (candidate !== requested) showFallback(requested, displayed);
                        return;
                    }
                    for (const [key, value] of page.searchParams) {
                        if (key.toLowerCase() !== 'view') target.searchParams.append(key, value);
                    }
                    setView(target, candidate);
                    if (!target.hash && anchor && uid === article.dataset.uid) target.hash = page.hash;
                    if (target.href === location.href) return;

                    if (candidate !== requested) {
                        try {
                            sessionStorage.setItem(noticeKey, JSON.stringify({ url: target.href, requested }));
                        } catch {
                            // Navigation can proceed without a notice when storage is unavailable.
                        }
                    }
                    location.assign(target.href);
                    return;
                }
                status.textContent = 'This API is unavailable in the configured documentation views.';
            } catch {
                status.textContent = 'Framework documentation could not be loaded.';
            } finally {
                select.disabled = false;
            }
        });
    }

    async function findUid(entry, uid) {
        const map = new URL(entry.xref, current);
        if (map.origin !== current.origin) throw new Error('Invalid framework xref URL.');
        const response = await fetch(map);
        if (!response.ok) throw new Error('Framework xref map could not be loaded.');

        // DocFX writes flat references with scalar UID and href fields. Read those two fields only.
        let matches = false;
        for (const line of (await response.text()).split(/\r?\n/)) {
            if (line.startsWith('- uid: ')) matches = scalar(line.slice(7)) === uid;
            if (!matches || !line.startsWith('  href: ')) continue;
            const target = new URL(scalar(line.slice(8)), map);
            if (target.origin === current.origin && target.pathname.startsWith(api)) return target;
            break;
        }
        return null;
    }

    function scalar(value) {
        if (value.startsWith("'")) return value.slice(1, -1).replaceAll("''", "'");
        if (value.startsWith('"')) return JSON.parse(value);
        return value;
    }
})();
