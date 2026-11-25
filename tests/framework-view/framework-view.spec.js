const { test, expect } = require('@playwright/test');

const runtime = '/api/runtime/FrameworkFixture.Runtime.';
const widget = runtime + 'Widget.html';
const reset = runtime + 'Widget.Reset.html';
const companion = runtime + 'Companion.html';
const modern = runtime + 'ModernFeature.html';
const legacy = runtime + 'LegacyFeature.html';
const utilities = '/api/utilities/FrameworkFixture.Utilities.html';
const utility = '/api/utilities/FrameworkFixture.Utilities.Utility.html';
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

test('manifest determines the framework labels and default selection', async ({ page, request }) => {
    const manifest = await (await request.get('/framework-views.json')).json();
    expect(manifest.apiPath).toBe('/api/');
    expect(manifest.viewOrder).toEqual([net11, net10, standard21, standard20, net48]);

    const defaultIndex = page.waitForResponse(response => new URL(response.url()).pathname === '/index.json');
    await page.goto(widget);
    expect((await defaultIndex).ok()).toBeTruthy();
    await expect(selector(page)).toBeVisible();
    await expect(selector(page)).toHaveValue(manifest.defaultView);
    await expect(selector(page).locator('option')).toHaveText([
        '.NET 11', '.NET 10', '.NET Standard 2.1', '.NET Standard 2.0', '.NET Framework 4.8'
    ]);
    await expect(page.locator(`article a[href$="${companion.split('/').pop()}"]`).first()).toBeVisible();
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

test('an encoded member fragment resolves through the native xref maps', async ({ page }) => {
    await page.goto(viewed(reset, net11));
    const declaration = page.locator('article [data-uid="FrameworkFixture.Runtime.Widget.Reset(System.Int32)"]');
    const id = await declaration.getAttribute('id');
    const encodedId = '%46' + id.slice(1);
    expect(decodeURIComponent(encodedId)).toBe(id);
    await page.goto(viewed(reset, net11) + '#' + encodedId);
    await selector(page).selectOption(standard20);
    await expect(page).toHaveURL(viewed(reset, standard21) + '#' + id);
    await expect(declaration).toBeVisible();
    await expect(selector(page)).toHaveValue(standard21);
    await expect(status(page)).toContainText('Showing .NET Standard 2.1.');
});

test('fallback navigates once to the nearest newer view and then keeps it', async ({ page, request }) => {
    await page.goto(viewed(modern, net11));
    await expect(selector(page)).toHaveValue(net11);
    const navigations = [];
    page.on('request', request => {
        if (request.isNavigationRequest()) navigations.push(request);
    });
    await selector(page).selectOption(standard21);
    await expect(page).toHaveURL(viewed(modern, net10));
    await expect(selector(page)).toHaveValue(net10);
    await expect(status(page)).toHaveText('This API is not documented for .NET Standard 2.1. Showing .NET 10.');
    await selector(page).selectOption(standard21);
    await expect(status(page)).toHaveText('This API is not documented for .NET Standard 2.1. Showing .NET 10.');
    await expect(selector(page)).toHaveValue(net10);
    expect(navigations.map(request => new URL(request.url()).search)).toEqual(['?view=' + net10]);
    expect(navigations[0].redirectedFrom()).toBeNull();
    const missing = await request.get(viewed(modern, standard21), { maxRedirects: 0 });
    expect(missing.status()).toBe(404);
    expect(missing.headers().location).toBeUndefined();
});

test('an API documented only in an older view stays there', async ({ page }) => {
    await page.goto(viewed(legacy, net48));
    await selector(page).selectOption(net11);
    await expect(status(page)).toHaveText('This API is not documented for .NET 11. Showing .NET Framework 4.8.');
    await expect(page).toHaveURL(viewed(legacy, net48));
    await expect(selector(page)).toHaveValue(net48);
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
    const result = await page.evaluate(async ({ companion, net10, net11 }) => {
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
        anchor.setAttribute('href', '/index.html?tag=a#guide');
        await new Promise(resolve => requestAnimationFrame(resolve));
        const concept = anchor.getAttribute('href');
        anchor.setAttribute('href', 'https://example.com/api/page.html?tag=a#guide');
        await new Promise(resolve => requestAnimationFrame(resolve));
        observer.disconnect();
        return { rewritten, expected, concept, external: anchor.getAttribute('href'), count: values.length };
    }, { companion, net10, net11 });
    expect(result.rewritten).toBe(result.expected);
    expect(result.concept).toBe('/index.html?tag=a#guide');
    expect(result.external).toBe('https://example.com/api/page.html?tag=a#guide');
    expect(result.count).toBe(3);
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
