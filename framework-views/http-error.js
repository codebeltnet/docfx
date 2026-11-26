(() => {
    const historyKey = 'docfx:last-document';
    const current = new URL(location.href);
    // The NGINX view argument is case-insensitive by name and uses the raw value.
    const requestedView = current.search.match(/(?:^\?|&)view=([^&]*)/i)?.[1];
    const byId = id => document.getElementById(id);

    function rememberPage() {
        const navigation = performance.getEntriesByType('navigation')[0];
        if (byId('docfx-http-error') || (navigation?.responseStatus >= 400)) return;
        const api = document.querySelector('meta[name="docfx:framework-api"]')?.content;
        const page = new URL(current.pathname, current.origin);
        if (page.origin !== current.origin) return;
        if (api && current.pathname.startsWith(api) && /^[a-z0-9.-]+$/.test(requestedView ?? '')) {
            page.searchParams.set('view', requestedView);
        }
        try {
            sessionStorage.setItem(historyKey, page.href);
        } catch {
            // Session storage may be unavailable in a restricted browser.
        }
    }

    async function isAvailable(url) {
        try {
            const response = await fetch(url, { method: 'HEAD', redirect: 'error', cache: 'no-store' });
            return response.ok && response.headers.get('content-type')?.startsWith('text/html');
        } catch {
            return false;
        }
    }

    function setupBack() {
        const back = byId('docfx-error-back');
        try {
            const previous = new URL(sessionStorage.getItem(historyKey));
            if (previous.origin === current.origin &&
                (previous.pathname !== current.pathname || previous.searchParams.get('view') !== (requestedView || null))) {
                back.href = previous.href;
            }
        } catch {
            // The link already points home when there is no session history.
        }
        back.hidden = false;
        back.addEventListener('click', async event => {
            event.preventDefault();
            location.assign(await isAvailable(back.href) ? back.href : '/');
        });
    }

    function setupSearch() {
        const search = byId('search-query');
        if (!search) return;
        const action = byId('docfx-error-search');
        const enable = () => {
            if (search.disabled) return;
            action.hidden = false;
            observer.disconnect();
        };
        const observer = new MutationObserver(enable);
        observer.observe(search, { attributes: true, attributeFilter: ['disabled'] });
        enable();
        byId('search-results')?.addEventListener('click', event => {
            // DocFX handles pagination in place. Its "#" links must stay on this URL.
            if (event.target.closest('a[href="#"]')) event.preventDefault();
        });
        action.addEventListener('click', () => {
            const panel = byId('navpanel');
            const toggle = document.querySelector('[aria-controls="navpanel"]');
            if (panel && toggle?.offsetWidth && !panel.classList.contains('show')) {
                panel.addEventListener('shown.bs.collapse', () => search.focus(), { once: true });
                toggle.click();
            } else {
                search.focus();
            }
        });
    }

    async function showFrameworkContext({ status, apiPath }) {
        if (!apiPath || !current.pathname.startsWith(apiPath)) return;
        try {
            const response = await fetch('/framework-views.json');
            if (!response.ok) return;
            const manifest = await response.json();
            if (manifest.schemaVersion !== 1 || manifest.apiPath !== apiPath) return;

            const selected = requestedView || manifest.defaultView;
            const label = manifest.views[selected]?.tfm;
            if (typeof label === 'string') showDetail('view', label);
            if (status !== '400' && status !== '404') return;
            const relative = decodeURIComponent(current.pathname.slice(apiPath.length));
            const page = relative.endsWith('/') || !relative ? relative + 'index.html' : relative;
            const setIndex = manifest.availability?.pages?.[page];
            if (typeof setIndex !== 'number') return;
            const available = manifest.availability.sets[setIndex];
            if (!Array.isArray(available) || (status === '400' && available.includes(selected))) return;
            if (!label && status === '404') return;

            // The build has already ordered and resolved this page's availability. Verify
            // the direct links in case the deployed files and inventory have drifted.
            const targets = await Promise.all(available.filter(view => view !== selected).map(async view => {
                const entry = manifest.views[view];
                if (typeof entry?.tfm !== 'string') return null;
                const target = new URL(current.pathname, current.origin);
                if (target.origin !== current.origin) return null;
                target.searchParams.set('view', view);
                if (!await isAvailable(target)) return null;
                const link = document.createElement('a');
                link.href = target.href;
                link.textContent = entry.tfm + (view === manifest.defaultView ? ' (default)' : '');
                const item = document.createElement('li');
                item.append(link);
                return item;
            }));
            const links = targets.filter(Boolean);
            if (!links.length) return;
            const message = byId('docfx-error-framework-message');
            message.textContent = label
                ? `${page} is unavailable for ${label}. Choose another target framework.`
                : `The selected framework is unrecognized. Open ${page} in one of the following target frameworks.`;
            message.hidden = false;
            const list = byId('docfx-error-framework-links');
            list.append(...links);
            list.hidden = false;
        } catch {
            // Missing or invalid metadata leaves the standard recovery actions available.
        }
    }

    function showDetail(name, value) {
        const detail = byId('docfx-error-' + name);
        detail.textContent = value;
        detail.hidden = false;
        byId('docfx-error-' + name + '-label').hidden = false;
    }

    function initialize() {
        const error = byId('docfx-http-error');
        if (!error) {
            rememberPage();
            addEventListener('pageshow', rememberPage);
            return;
        }
        showDetail('path', current.pathname);
        setupBack();
        setupSearch();
        if (['500', '502', '503', '504'].includes(error.dataset.status)) {
            const retry = byId('docfx-error-retry');
            retry.hidden = false;
            // A fresh navigation retries the URL as a GET, including after a failed POST.
            retry.addEventListener('click', () => location.assign(current.href));
        }
        showFrameworkContext(error.dataset);
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', initialize, { once: true });
    } else {
        initialize();
    }
})();
