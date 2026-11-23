(() => {
    const meta = name => document.querySelector(`meta[name="docfx:${name}"]`);
    const current = new URL(location.href);
    const api = meta('framework-api').content;
    // Match NGINX's $arg_view lookup, which is case-insensitive for the argument name.
    const view = current.search.match(/(?:^\?|&)view=([^&]*)/i)?.[1];
    if (!current.pathname.startsWith(api)) return;
    document.addEventListener('DOMContentLoaded', initializeSelector);
    if (!view) return;

    const toc = meta('tocrel');
    if (toc?.content) {
        const url = new URL(toc.content.replace(/\.html$/i, '.json'), current);
        if (url.origin === current.origin && url.pathname.startsWith(api)) {
            url.searchParams.set('view', view);
            toc.content = url.href;
        }
    }

    const searchRoot = `/_framework-search/${meta('framework-directory').content}/`;
    const search = meta('rel');
    if (search) search.content = searchRoot;

    function preserveView(anchor) {
        const href = anchor.getAttribute('href');
        if (!href || href.startsWith('#')) return;
        const url = new URL(href, current);
        if (url.origin !== current.origin) return;
        const fromSearch = url.pathname.startsWith(searchRoot);
        if (fromSearch) url.pathname = '/' + url.pathname.slice(searchRoot.length);
        const isApi = url.pathname.startsWith(api);
        if (isApi) url.searchParams.set('view', view);
        if (fromSearch || isApi) {
            const canonical = url.pathname + url.search + url.hash;
            if (canonical !== href) anchor.setAttribute('href', canonical);
            if (fromSearch && anchor.matches('#search-results .item-title > a')) {
                anchor.dataset.frameworkUrl = url.pathname + (isApi ? `?view=${encodeURIComponent(view)}` : '') + url.hash;
            }
        }
    }

    function updateLinks(node) {
        if (node instanceof HTMLAnchorElement) preserveView(node);
        node.querySelectorAll?.('a[href]').forEach(preserveView);
    }

    // DocFX renders the TOC, breadcrumbs, prev/next and search results after the HTML loads.
    // Observe href changes too because its renderer reuses links on search and TOC updates.
    new MutationObserver(records => {
        for (const record of records) {
            if (record.target instanceof HTMLAnchorElement) preserveView(record.target);
            for (const node of record.addedNodes) updateLinks(node);
        }
    }).observe(document.documentElement, {
        subtree: true, childList: true, attributes: true, attributeFilter: ['href']
    });
    document.addEventListener('DOMContentLoaded', () => updateLinks(document));

    function frameworkName(entry) {
        const match = /^(netstandard|netcoreapp|net)(\d+)\.(\d+)$/.exec(entry.tfm);
        if (!match) return entry.tfm;
        const product = { netstandard: '.NET Standard', netcoreapp: '.NET Core', net: '.NET' }[match[1]];
        const version = match[1] === 'net' && match[3] === '0' ? match[2] : `${match[2]}.${match[3]}`;
        return `${product} ${version}`;
    }

    async function initializeSelector() {
        const container = document.getElementById('framework-view');
        const article = document.querySelector('article[data-uid]');
        if (!container || !article?.dataset.uid) return;

        let manifest;
        try {
            const response = await fetch('/framework-views.json');
            if (!response.ok) return;
            manifest = await response.json();
        } catch {
            return;
        }
        if (manifest.schemaVersion !== 1 || manifest.apiPath !== api) return;

        const displayed = view || manifest.defaultView;
        const order = manifest.viewOrder ?? Object.keys(manifest.views);
        if (order.length < 2 || !order.includes(displayed)) return;

        const select = document.getElementById('framework-view-select');
        const status = document.getElementById('framework-view-status');
        for (const id of order) select.add(new Option(frameworkName(manifest.views[id]), id));
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
            status.textContent = `This API is not documented for ${frameworkName(manifest.views[requested])}. Showing ${frameworkName(manifest.views[selected])}.`;
        }

        select.addEventListener('change', async () => {
            const requested = select.value;
            select.value = displayed;
            select.disabled = true;
            status.textContent = '';
            try {
                const page = new URL(location.href);
                const fragment = page.hash.slice(1);
                const anchor = document.getElementById(fragment) || document.getElementById(decodeURIComponent(fragment));
                const uid = anchor?.dataset.uid || article.dataset.uid;
                const index = order.indexOf(requested);
                const candidates = new Set([requested, ...order.slice(0, index).reverse(), displayed, ...order.slice(index + 1)]);
                for (const candidate of candidates) {
                    const target = await findUid(manifest.views[candidate], uid);
                    if (!target) continue;

                    if (candidate === displayed) {
                        if (candidate !== requested) showFallback(requested, displayed);
                        return;
                    }
                    for (const [key, value] of page.searchParams) {
                        if (key.toLowerCase() !== 'view') target.searchParams.append(key, value);
                    }
                    target.searchParams.set('view', candidate);
                    if (!target.hash) target.hash = page.hash;
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
