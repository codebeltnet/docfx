const { test, expect } = require('@playwright/test');

const runtime = '/api/runtime/FrameworkFixture.Runtime.';
const widget = runtime + 'Widget.html';
const reset = runtime + 'Widget.Reset.html';
const companion = runtime + 'Companion.html';
const modern = runtime + 'ModernFeature.html';
const standard = runtime + 'StandardFeature.html';
const legacy = runtime + 'LegacyFeature.html';
const missingPage = runtime + 'MissingPage.html';
const utilities = '/api/utilities/FrameworkFixture.Utilities.html';
const utility = '/api/utilities/FrameworkFixture.Utilities.Utility.html';
const modernNamespace = '/api/modern/FrameworkFixture.ModernApi.html';
const modernEndpoint = '/api/modern/FrameworkFixture.ModernApi.Endpoint.html';
const standardNamespace = '/api/standard/FrameworkFixture.StandardApi.html';
const standardAdapter = '/api/standard/FrameworkFixture.StandardApi.Adapter.html';
const net11 = 'net-11.0';
const net10 = 'net-10.0';
const standard21 = 'netstandard-2.1';
const standard20 = 'netstandard-2.0';
const net48 = 'net48';
const viewed = (path, view) => path + '?view=' + view;
const selector = page => page.getByRole('combobox', { name: 'Framework' });
const status = page => page.locator('#framework-view-status');
const search = page => page.getByRole('searchbox', { name: 'Search', exact: true });
const searchHits = page => page.locator('#search-results .item-title > a');
const pageErrors = new WeakMap();

test.beforeEach(async ({ page }) => {
    const errors = [];
    pageErrors.set(page, errors);
    page.on('pageerror', error => errors.push(error.message));
    page.on('response', response => {
        if (response.url().startsWith(process.env.DOCFX_TEST_ORIGIN) && response.status() >= 400) {
            errors.push(`${response.status()} ${response.url()}`);
        }
    });
});

test.afterEach(async ({ page }) => {
    expect(pageErrors.get(page)).toEqual([]);
});

test('manifest determines the framework labels, availability and default selection', async ({ page, request }) => {
    const manifest = await (await request.get('/framework-views.json')).json();
    expect(manifest.apiPath).toBe('/api/');
    expect(manifest.viewOrder).toEqual([net11, net10, standard21, standard20, net48]);
    expect(manifest.availability.sets[manifest.availability.pages['modern/FrameworkFixture.ModernApi.Endpoint.html']]).toEqual([net11, net10]);
    expect(manifest.availability.sets[manifest.availability.pages['standard/FrameworkFixture.StandardApi.Adapter.html']]).toEqual([standard21, standard20]);
    expect(manifest.availability.sets[manifest.availability.pages['runtime/FrameworkFixture.Runtime.LegacyFeature.html']]).toEqual([net48]);

    const defaultIndex = page.waitForResponse(response => new URL(response.url()).pathname === '/index.json');
    await page.goto(widget);
    expect((await defaultIndex).ok()).toBeTruthy();
    await expect(selector(page)).toBeVisible();
    await expect(selector(page)).toHaveValue(manifest.defaultView);
    await expect(selector(page).locator('option')).toHaveText([
        '.NET 11', '.NET 10', '.NET Standard 2.1', '.NET Standard 2.0', '.NET Framework 4.8'
    ]);
    await expect(page.locator(`article a[href$="${companion.split('/').pop()}"]`).first()).toBeVisible();
    await expect(page.locator(`#navbar a[href="${viewed(standardNamespace, standard21)}"]`).first()).toBeVisible();
    await expect(page).toHaveURL(widget);

    await page.goto('/index.html');
    await expect(selector(page)).toBeHidden();
});

test('same UID switches with the valid article fragment and repeated query parameters', async ({ page }) => {
    await page.goto(widget + '?tag=a&tag=b');
    const id = await page.locator('article h1').getAttribute('id');
    const hash = '#' + id;
    await page.goto(widget + '?tag=a&tag=b' + hash);
    await selector(page).selectOption(net10);
    await expect(page).toHaveURL(widget + '?tag=a&tag=b&view=' + net10 + hash);
    await expect(selector(page)).toHaveValue(net10);
    await expect(page.locator('article h1')).toHaveAttribute('id', id);
    await expect(page.locator('article')).toHaveAttribute('data-uid', 'FrameworkFixture.Runtime.Widget');
});

for (const fragment of ['#missing%', '#%FF', '#unknown-anchor']) {
    test(`unresolvable fragment ${fragment} falls back to the article UID`, async ({ page }) => {
        await page.goto(widget + '?tag=source' + fragment);
        await selector(page).selectOption(net10);
        await expect(page).toHaveURL(widget + '?tag=source&view=' + net10);
        await expect(selector(page)).toHaveValue(net10);
        await expect(status(page)).toBeEmpty();
    });
}

test('an encoded member fragment resolves through the native xref maps using unified precedence', async ({ page }) => {
    await page.goto(viewed(reset, net10));
    const declaration = page.locator('article [data-uid="FrameworkFixture.Runtime.Widget.Reset(System.Int32)"]');
    const id = await declaration.getAttribute('id');
    const encodedId = '%46' + id.slice(1);
    expect(decodeURIComponent(encodedId)).toBe(id);
    await page.goto(viewed(reset, net10) + '#' + encodedId);
    await selector(page).selectOption(standard20);
    await expect(page).toHaveURL(viewed(reset, net11) + '#' + id);
    await expect(declaration).toBeVisible();
    await expect(selector(page)).toHaveValue(net11);
    await expect(status(page)).toContainText('Showing .NET 11.');
});

test('selector fallback targets the first framework in precedence order for both default and non-default APIs', async ({ page }) => {
    // Fallback targeting the default framework (.NET 11)
    await page.goto(viewed(modern, net10));
    await expect(selector(page)).toHaveValue(net10);
    const navigations = [];
    page.on('request', request => {
        if (request.isNavigationRequest()) navigations.push(request);
    });
    await selector(page).selectOption(standard21);
    await expect(page).toHaveURL(viewed(modern, net11));
    await expect(selector(page)).toHaveValue(net11);
    await expect(status(page)).toHaveText('This API is not documented for .NET Standard 2.1. Showing .NET 11.');
    await selector(page).selectOption(standard21);
    await expect(status(page)).toHaveText('This API is not documented for .NET Standard 2.1. Showing .NET 11.');
    await expect(selector(page)).toHaveValue(net11);
    expect(navigations.map(request => new URL(request.url()).search)).toEqual(['?view=' + net11]);
    expect(navigations[0].redirectedFrom()).toBeNull();

    // Fallback targeting a non-default framework (.NET Standard 2.1)
    await page.goto(viewed(standard, standard20));
    await expect(selector(page)).toHaveValue(standard20);
    await selector(page).selectOption(net11);
    await expect(page).toHaveURL(viewed(standard, standard21));
    await expect(selector(page)).toHaveValue(standard21);
    await expect(status(page)).toHaveText('This API is not documented for .NET 11. Showing .NET Standard 2.1.');
});

test('an API documented only in an older view stays there', async ({ page }) => {
    await page.goto(viewed(legacy, net48));
    await selector(page).selectOption(net11);
    await expect(status(page)).toHaveText('This API is not documented for .NET 11. Showing .NET Framework 4.8.');
    await expect(page).toHaveURL(viewed(legacy, net48));
    await expect(selector(page)).toHaveValue(net48);
});

test('global navigation resolves unavailable API sections to default and non-default fallbacks and preserves available views', async ({ page }) => {
    // Reproduces the Cuemon scenario: on netstandard-2.0, click an API section only available in modern .NET -> falls back to net-11.0
    await page.goto(viewed(widget, standard20));
    await expect(selector(page)).toHaveValue(standard20);
    const modernNavLink = page.locator(`#navbar a[href="${viewed(modernNamespace, net11)}"]`).first();
    await expect(modernNavLink).toBeVisible();
    const modernToc = page.waitForResponse(response => {
        const url = new URL(response.url());
        return url.pathname === '/api/modern/toc.json' && url.searchParams.get('view') === net11;
    });
    const modernIndex = page.waitForResponse(response => new URL(response.url()).pathname === '/_framework-search/net11/index.json');
    await modernNavLink.click();
    await expect(page).toHaveURL(viewed(modernNamespace, net11));
    expect((await modernToc).ok()).toBeTruthy();
    expect((await modernIndex).ok()).toBeTruthy();
    await expect(selector(page)).toHaveValue(net11);
    await expect(page.locator('article h1')).toContainText('FrameworkFixture.ModernApi');
    await expect(page.locator(`#toc a[href="${viewed(modernEndpoint, net11)}"]`).first()).toBeVisible();

    // Browser history Back/Forward works cleanly without redirect traps
    await page.goBack();
    await expect(page).toHaveURL(viewed(widget, standard20));
    await expect(selector(page)).toHaveValue(standard20);
    await page.goForward();
    await expect(page).toHaveURL(viewed(modernNamespace, net11));
    await expect(selector(page)).toHaveValue(net11);

    // On net-10.0, clicking Modern API preserves net-10.0
    await page.goto(viewed(widget, net10));
    await page.locator(`#navbar a[href="${viewed(modernNamespace, net10)}"]`).first().click();
    await expect(page).toHaveURL(viewed(modernNamespace, net10));
    await expect(selector(page)).toHaveValue(net10);

    // On net-11.0, clicking Standard API (unavailable in net-11.0 and net-10.0) falls back to non-default netstandard-2.1
    await page.goto(viewed(widget, net11));
    const standardNavLink = page.locator(`#navbar a[href="${viewed(standardNamespace, standard21)}"]`).first();
    await expect(standardNavLink).toBeVisible();
    const standardToc = page.waitForResponse(response => {
        const url = new URL(response.url());
        return url.pathname === '/api/standard/toc.json' && url.searchParams.get('view') === standard21;
    });
    const standardIndex = page.waitForResponse(response => new URL(response.url()).pathname === '/_framework-search/netstandard2.1/index.json');
    await standardNavLink.click();
    await expect(page).toHaveURL(viewed(standardNamespace, standard21));
    expect((await standardToc).ok()).toBeTruthy();
    expect((await standardIndex).ok()).toBeTruthy();
    await expect(selector(page)).toHaveValue(standard21);
    await expect(page.locator('article h1')).toContainText('FrameworkFixture.StandardApi');
    await expect(page.locator(`#toc a[href="${viewed(standardAdapter, standard21)}"]`).first()).toBeVisible();

    // On netstandard-2.0, clicking Standard API preserves netstandard-2.0
    await page.goto(viewed(widget, standard20));
    await page.locator(`#navbar a[href="${viewed(standardNamespace, standard20)}"]`).first().click();
    await expect(page).toHaveURL(viewed(standardNamespace, standard20));
    await expect(selector(page)).toHaveValue(standard20);
});

test('ordinary internal API hyperlinks resolve availability, preserve query/fragment and support new tabs without click interception', async ({ page, context }) => {
    await page.goto(viewed(widget, standard20));
    await expect(page.locator(`article a[href="${viewed(modern, net11)}"]`)).toBeVisible();
    await expect(page.locator(`article a[href="${viewed(standard, standard20)}"]`)).toBeVisible();
    await expect(page.locator(`article a[href="${viewed(legacy, net48)}"]`)).toBeVisible();
    await expect(page.locator(`article a[href="${modernEndpoint}?source=remarks&view=${net11}#details"]`)).toBeVisible();
    await expect(page.locator(`article a[href="${standardAdapter}?source=remarks&view=${standard20}#details"]`)).toBeVisible();
    // Genuine missing page keeps the requested view rather than fabricating a fallback.
    await expect(page.locator(`article a[href="${viewed(missingPage, standard20)}"]`)).toBeVisible();

    // Open a resolved fallback hyperlink in a new tab using a plain middle-click (no JS click handler interception).
    const endpointLink = page.locator(`article a[href="${modernEndpoint}?source=remarks&view=${net11}#details"]`);
    const [tab] = await Promise.all([
        context.waitForEvent('page'),
        endpointLink.click({ button: 'middle' })
    ]);
    await expect(tab).toHaveURL(`${modernEndpoint}?source=remarks&view=${net11}#details`);
    await expect(selector(tab)).toHaveValue(net11);
    await expect(tab.locator('article h1')).toContainText('Endpoint Class');
    await tab.close();

    // Conceptual pages also resolve API links targeting unavailable views or non-default-only APIs.
    await page.goto('/index.html');
    await expect(page.locator(`article a[href="${modernEndpoint.slice(1)}"]`).first()).toBeVisible();
    await expect(page.locator(`article a[href="${viewed(modernEndpoint, net11)}"]`).first()).toBeVisible();
    await expect(page.locator(`article a[href="${viewed(standardAdapter, standard21)}"]`).first()).toBeVisible();
    await expect(page.locator(`article a[href="${viewed(standardAdapter.slice(1), standard20)}"]`).first()).toBeVisible();
    await expect(page.locator(`article a[href$="${missingPage.split('/').pop()}"]`).first()).toBeVisible();
});

test('JavaScript-disabled navigation resolves fallback via HTTP 302 and preserves query parameters, fragments and history', async ({ browser }) => {
    const context = await browser.newContext({ javaScriptEnabled: false });
    const page = await context.newPage();
    try {
        await page.goto(viewed(widget, standard20));
        await expect(page).toHaveURL(viewed(widget, standard20));

        // Direct navigation to default fallback with unrelated query params and fragment
        await page.goto(`${modernEndpoint}?tag=a&view=${standard20}&tag=b#details`);
        await expect(page).toHaveURL(`${modernEndpoint}?tag=a&tag=b&view=${net11}#details`);
        await expect(page.locator('article h1')).toContainText('Endpoint Class');

        // Back/Forward across server-side 302 redirect has no redirect loop
        await page.goBack();
        await expect(page).toHaveURL(viewed(widget, standard20));
        await page.goForward();
        await expect(page).toHaveURL(`${modernEndpoint}?tag=a&tag=b&view=${net11}#details`);

        // Clicking a static HTML link in Widget remarks to a non-default-only API while JS is disabled triggers HTTP 302
        await page.goto(widget);
        await page.locator('article a', { hasText: 'Standard Adapter link' }).click();
        await expect(page).toHaveURL(`${standardAdapter}?source=remarks&view=${standard21}#details`);
        await expect(page.locator('article h1')).toContainText('Adapter Class');
    } finally {
        await context.close();
    }
});

test('direct HTTP routing redirects unavailable page/framework combinations with 302 and preserves 404, 400 and isolation', async ({ request }) => {
    const redirectCases = [
        // Unavailable section -> default fallback
        { from: viewed(modernEndpoint, standard20), to: viewed(modernEndpoint, net11) },
        { from: viewed(modernEndpoint, standard21), to: viewed(modernEndpoint, net11) },
        { from: `${modernEndpoint}?tag=a&view=${standard20}&tag=b`, to: `${modernEndpoint}?tag=a&tag=b&view=${net11}` },
        { from: `${modernEndpoint}?VIEW=${standard20}&tag=a`, to: `${modernEndpoint}?tag=a&view=${net11}` },
        { from: `${modernEndpoint}?tag=a&VIEW=${standard20}&view=${standard21}&tag=b`, to: `${modernEndpoint}?tag=a&tag=b&view=${net11}` },
        { from: viewed(modern, standard21), to: viewed(modern, net11) },
        // Unavailable section / type -> non-default fallback
        { from: standardAdapter, to: viewed(standardAdapter, standard21) },
        { from: viewed(standardAdapter, net11), to: viewed(standardAdapter, standard21) },
        { from: `${standardAdapter}?tag=x&tag=y`, to: `${standardAdapter}?tag=x&tag=y&view=${standard21}` },
        { from: viewed(standardAdapter, net48), to: viewed(standardAdapter, standard21) },
        { from: viewed(standard, net10), to: viewed(standard, standard21) },
        { from: legacy, to: viewed(legacy, net48) },
        { from: viewed(legacy, net11), to: viewed(legacy, net48) },
        { from: `${legacy}?view=`, to: viewed(legacy, net48) }
    ];

    for (const item of redirectCases) {
        const response = await request.get(item.from, { maxRedirects: 0 });
        expect(response.status(), item.from).toBe(302);
        expect(response.headers().location, item.from).toBe(item.to);
        expect(response.headers()['cache-control'], item.from).toContain('no-store');
        expect(response.headers().etag, item.from).toBeUndefined();

        const followed = await request.get(item.to, { maxRedirects: 0 });
        expect(followed.status(), item.to).toBe(200);
        expect(followed.headers().location, item.to).toBeUndefined();
    }

    // Preserved available views return 200 directly
    for (const okPath of [
        viewed(modernEndpoint, net10),
        viewed(standardAdapter, standard20),
        viewed(legacy, net48),
        '/xrefmap.yml?view=' + standard20,
        '/index.html?view=unknown',
        '/public/docfx.min.css?view=unknown'
    ]) {
        const ok = await request.get(okPath, { maxRedirects: 0 });
        expect(ok.status(), okPath).toBe(200);
    }

    // Genuine missing pages, non-HTML API resources and internal framework directories return 404 without redirecting
    for (const notFoundPath of [
        missingPage,
        viewed(missingPage, standard20),
        '/api/modern/toc.json?view=' + standard20,
        '/api/standard/toc.json',
        '/api/modern/missing.png?view=' + standard20,
        '/_frameworks/net10' + widget
    ]) {
        const notFound = await request.get(notFoundPath, { maxRedirects: 0 });
        expect(notFound.status(), notFoundPath).toBe(404);
        expect(notFound.headers().location, notFoundPath).toBeUndefined();
    }

    // Unknown or wrong-case framework identifiers return 400 without redirecting
    for (const badViewPath of [
        viewed(modernEndpoint, 'unknown'),
        viewed(modernEndpoint, 'NET-11.0'),
        viewed(missingPage, 'unknown'),
        '/xrefmap.yml?view=unknown',
        `${modernEndpoint}?view=${standard20}&view=${standard21}&view=${net48}`
    ]) {
        const bad = await request.get(badViewPath, { maxRedirects: 0 });
        expect(bad.status(), badViewPath).toBe(400);
        expect(bad.headers().location, badViewPath).toBeUndefined();
    }
});

test('native TOC, breadcrumbs and cross-references stay in the view after reload and history', async ({ page }) => {
    const toc = page.waitForResponse(response => {
        const url = new URL(response.url());
        return url.pathname === '/api/runtime/toc.json' && url.searchParams.get('view') === net10;
    });
    // NGINX accepts case-insensitive argument names.
    const direct = widget + '?VIEW=' + net10;
    await page.goto(direct);
    expect((await toc).ok()).toBeTruthy();
    await expect(selector(page)).toHaveValue(net10);
    await expect(page.locator(`#breadcrumb a[href^="${viewed('/api/runtime/FrameworkFixture.Runtime.html', net10)}"]`).first()).toBeVisible();
    await expect(page.locator('#navbar a[href$="index.html"]').first()).toBeVisible();
    const external = page.locator('footer a[href="https://dotnet.github.io/docfx"]');
    await expect(external).toBeVisible();

    await page.locator(`article a[href="${viewed(companion, net10)}"]`).first().press('Enter');
    await expect(page).toHaveURL(viewed(companion, net10));
    await page.goBack();
    await expect(page).toHaveURL(direct);
    await expect(selector(page)).toHaveValue(net10);
    await page.goForward();
    await expect(page).toHaveURL(viewed(companion, net10));
    await page.reload();
    await expect(selector(page)).toHaveValue(net10);
    await expect(search(page)).toBeEnabled();
    await search(page).fill('ModernFeature');
    await expect(searchHits(page).filter({ hasText: 'ModernFeature' }).first())
        .toHaveAttribute('href', modern + '?q=ModernFeature&view=' + net10);
    await search(page).clear();

    await page.getByRole('searchbox', { name: 'Filter by title' }).fill('Widget');
    await page.locator(`#toc a[href="${viewed(widget, net10)}"]`).first().press('Enter');
    await expect(page).toHaveURL(viewed(widget, net10));
    await page.locator(`#navbar a[href="${viewed(utilities, net10)}"]`).click();
    await expect(page).toHaveURL(viewed(utilities, net10));
    await page.locator(`#toc a[href="${viewed(utility, net10)}"]`).first().click();
    await expect(page).toHaveURL(viewed(utility, net10));
});

test('explicit views load the index for the manifest directory', async ({ page, request }) => {
    const manifest = await (await request.get('/framework-views.json')).json();
    for (const view of manifest.viewOrder) {
        const expected = `/_framework-search/${manifest.views[view].directory}/index.json`;
        const index = page.waitForResponse(response => new URL(response.url()).pathname === expected);
        await page.goto(viewed(widget, view));
        expect((await index).ok()).toBeTruthy();
        await expect(selector(page)).toHaveValue(view);
    }
});

test('dynamic links preserve query and fragment without repeated DOM updates', async ({ page }) => {
    await page.goto(viewed(widget, net10));
    const result = await page.evaluate(async ({ companion, legacy, net10, net11, net48 }) => {
        const anchor = document.createElement('a');
        const initial = `${companion}?tag=a&tag=b&VIEW=${net11}&view=${net11}#details`;
        const expected = `${companion}?tag=a&tag=b&view=${net10}#details`;
        anchor.setAttribute('href', initial);
        const values = [];
        const observer = new MutationObserver(records => values.push(...records.map(record => record.oldValue)));
        observer.observe(anchor, { attributes: true, attributeFilter: ['href'], attributeOldValue: true });
        document.querySelector('article').append(anchor);
        await new Promise(resolve => requestAnimationFrame(resolve));
        const rewritten = anchor.getAttribute('href');
        anchor.setAttribute('href', `${legacy}?tag=a#details`);
        await new Promise(resolve => requestAnimationFrame(resolve));
        const fallback = anchor.getAttribute('href');
        anchor.setAttribute('href', '/index.html?tag=a#guide');
        await new Promise(resolve => requestAnimationFrame(resolve));
        const concept = anchor.getAttribute('href');
        anchor.setAttribute('href', 'https://example.com/api/page.html?tag=a#guide');
        await new Promise(resolve => requestAnimationFrame(resolve));
        observer.disconnect();
        return {
            rewritten,
            expected,
            fallback,
            expectedFallback: `${legacy}?tag=a&view=${net48}#details`,
            concept,
            external: anchor.getAttribute('href'),
            count: values.length
        };
    }, { companion, legacy, net10, net11, net48 });
    expect(result.rewritten).toBe(result.expected);
    expect(result.fallback).toBe(result.expectedFallback);
    expect(result.concept).toBe('/index.html?tag=a#guide');
    expect(result.external).toBe('https://example.com/api/page.html?tag=a#guide');
    expect(result.count).toBe(5);
});

for (const [view, term, expected] of [[net10, 'ModernFeature', modern], [net48, 'LegacyFeature', legacy]]) {
    test(`native search uses the ${view} index and displays public URLs`, async ({ page, request }) => {
        const manifest = await (await request.get('/framework-views.json')).json();
        const directory = manifest.views[view].directory;
        const index = page.waitForResponse(response => new URL(response.url()).pathname === `/_framework-search/${directory}/index.json`);
        await page.goto(viewed(widget, view));
        expect((await index).ok()).toBeTruthy();
        await expect(search(page)).toBeEnabled();
        await search(page).fill(view === net10 ? 'LegacyFeature' : 'ModernFeature');
        await expect(page.locator('#search-results .search-list')).toContainText(/no results/i);
        await search(page).fill(term);

        const result = searchHits(page).filter({ hasText: term }).first();
        const href = `${expected}?q=${term}&view=${view}`;
        await expect(result).toHaveAttribute('href', href);
        await expect(result).toHaveAttribute('data-framework-url', viewed(expected, view));
        await expect(result.locator('xpath=../../div[@class="item-href"]')).toBeHidden();
        expect(await result.evaluate(link => JSON.parse(getComputedStyle(link, '::after').content))).toBe(viewed(expected, view));
        const [popup] = await Promise.all([page.waitForEvent('popup'), result.press('Enter')]);
        await expect(popup).toHaveURL(href);
        await expect(selector(popup)).toHaveValue(view);
        await popup.close();

        // The result elements can be reused when the query changes.
        await search(page).fill('compass');
        const concept = searchHits(page).filter({ hasText: 'Concept guide' });
        await expect(concept).toHaveAttribute('href', '/index.html?q=compass');
        await expect(concept).toHaveAttribute('data-framework-url', '/index.html');
    });
}

for (const colorScheme of ['light', 'dark']) {
    test.describe(colorScheme, () => {
        test.use({ viewport: { width: 390, height: 844 }, colorScheme });

        test('mobile TOC exposes the keyboard-operable selector', async ({ page }) => {
            await page.goto(widget);
            await expect(selector(page)).toBeHidden();
            await page.getByRole('button', { name: 'Show table of contents' }).press('Enter');
            await expect(selector(page)).toBeVisible();
            await expect(page.locator('html')).toHaveAttribute('data-bs-theme', colorScheme);
            await selector(page).focus();
            await expect(selector(page)).toBeFocused();
            await selector(page).press('ArrowDown');
            await expect(page).toHaveURL(viewed(widget, net10));
            await page.getByRole('button', { name: 'Show table of contents' }).click();
            await expect(selector(page)).toHaveValue(net10);
        });
    });
}

test('a normal single-framework site uses native navigation and search', async ({ page }) => {
    await page.goto('/single' + widget);
    await expect(page.locator('meta[name="docfx:framework-api"]')).toHaveCount(0);
    await expect(selector(page)).toHaveCount(0);
    await expect(page.locator(`#toc a[href$="${widget}"]`).first()).toBeVisible();
    await expect(search(page)).toBeEnabled();
    await search(page).fill('ModernFeature');
    const result = searchHits(page).filter({ hasText: 'ModernFeature' }).first();
    await expect(result).toBeVisible();
    const href = new URL(await result.getAttribute('href'), page.url());
    expect(href.pathname).toBe('/single' + modern);
    expect(href.search).toBe('?q=ModernFeature');
    await expect(result.locator('xpath=../../div[@class="item-href"]')).toBeVisible();
});
