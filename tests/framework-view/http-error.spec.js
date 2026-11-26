const { test, expect } = require('@playwright/test');

const endpoint = '/api/modern/FrameworkFixture.ModernApi.Endpoint.html';
const widget = '/api/runtime/FrameworkFixture.Runtime.Widget.html';
const missing = '/deep/nested/documentation/does-not-exist.html';
const back = page => page.getByRole('link', { name: 'Go back' });
const heading = (page, name) => page.getByRole('heading', { name, exact: true });
const alternatives = page => page.locator('#docfx-error-framework-links a');

test('deep document errors reuse branding, assets, navigation and search', async ({ page, request }) => {
    const assetErrors = [];
    page.on('response', response => {
        if (response.status() >= 400 && !response.request().isNavigationRequest()) {
            assetErrors.push(new URL(response.url()).pathname);
        }
    });
    expect((await page.goto(missing)).status()).toBe(404);
    await expect(heading(page, 'Not Found')).toBeVisible();
    await expect(page.locator('html')).toHaveAttribute('lang', 'en');
    await expect(page.locator('.navbar-brand')).toContainText('Framework Fixture');
    await expect(page.locator('#navbar a[href$="/index.html"]').first()).toBeVisible();
    await expect(page.locator('footer')).toBeVisible();
    await expect(page.locator('#docfx-http-error')).toHaveCSS('padding-top', '24px');
    expect((await page.reload()).status()).toBe(404);
    await expect(page).toHaveURL(missing);
    await expect(alternatives(page)).toHaveCount(0);
    await expect(back(page)).toHaveAttribute('href', '/');

    await page.getByRole('button', { name: 'Search documentation' }).click();
    const search = page.getByRole('searchbox', { name: 'Search', exact: true });
    await expect(search).toBeFocused();
    await search.fill('compass');
    await expect(page.locator('#search-results .item-title a').first()).toHaveAttribute('href', '/index.html?q=compass');
    expect(assetErrors).toEqual([]);

    const index = await request.get('/index.json');
    expect(await index.text()).not.toContain('_docfx-errors');
});

test('recovery remembers the last successful document across consecutive errors', async ({ page }) => {
    const previous = widget + '?view=net-10.0';
    expect((await page.goto(previous + '&tag=discarded')).status()).toBe(200);
    expect((await page.goto(missing + '?token=secret-query-value')).status()).toBe(404);
    await page.getByText('Technical details').click();
    await expect(page.locator('#docfx-error-path')).toHaveText(missing);
    await expect(page.locator('#docfx-http-error')).not.toContainText('secret-query-value');
    const other = '/%3Cstrong%3Epath%3C%2Fstrong%3E.html';
    expect((await page.goto(other)).status()).toBe(404);
    await page.getByText('Technical details').click();
    await expect(page.locator('#docfx-error-path')).toHaveText(other);
    await expect(page.locator('#docfx-error-path strong')).toHaveCount(0);
    await back(page).click();
    await expect(page).toHaveURL(previous);
    await expect(page.locator('#docfx-http-error')).toHaveCount(0);
});

test('automatic fallback takes precedence and an invalid request lists only working frameworks', async ({ page, request }) => {
    const unavailable = endpoint + '?view=netstandard-2.0';
    const fallback = await request.get(unavailable, { maxRedirects: 0 });
    expect(fallback.status()).toBe(302);
    expect(fallback.headers().location).toBe(endpoint + '?view=net-11.0');
    expect((await page.goto(unavailable)).status()).toBe(200);
    await expect(page).toHaveURL(endpoint + '?view=net-11.0');

    const rejected = unavailable + '&view=netstandard-2.0&view=netstandard-2.0&token=secret-query-value';
    expect((await page.goto(rejected)).status()).toBe(400);
    await expect(heading(page, 'Bad Request')).toBeVisible();
    await expect(page.locator('#docfx-error-framework-message')).toContainText('unavailable for netstandard2.0');
    await expect(alternatives(page)).toHaveText(['net11.0 (default)', 'net10.0']);
    await page.getByText('Technical details').click();
    await expect(page.locator('#docfx-error-view')).toHaveText('netstandard2.0');
    await expect(page.locator('#docfx-http-error')).not.toContainText('secret-query-value');
    for (const link of await alternatives(page).all()) {
        expect((await request.get(await link.getAttribute('href'), { maxRedirects: 0 })).status()).toBe(200);
    }
    await alternatives(page).last().click();
    await expect(page).toHaveURL(endpoint + '?view=net-10.0');
});

test('missing framework metadata leaves standard actions available', async ({ page }) => {
    const metadata = page.waitForResponse(response => new URL(response.url()).pathname === '/framework-views.json');
    await page.route('**/framework-views.json', route => route.fulfill({ status: 404 }));
    expect((await page.goto(endpoint + '?view=unavailable')).status()).toBe(400);
    await metadata;
    await expect(heading(page, 'Bad Request')).toBeVisible();
    await expect(alternatives(page)).toHaveCount(0);
    await back(page).click();
    await expect(page).toHaveURL('/');
});

test('themes and search work on a narrow viewport', async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 740 });
    await page.emulateMedia({ colorScheme: 'dark' });
    await page.goto(missing);
    await expect(page.locator('html')).toHaveAttribute('data-bs-theme', 'dark');
    for (const theme of ['light', 'dark']) {
        await page.evaluate(theme => localStorage.setItem('theme', theme), theme);
        await page.reload();
        await expect(page.locator('html')).toHaveAttribute('data-bs-theme', theme);
        await expect(page.locator('body')).toHaveCSS('background-color',
            theme === 'light' ? 'rgb(255, 255, 255)' : 'rgb(27, 27, 27)');
    }
    await page.getByRole('button', { name: 'Search documentation' }).click();
    await expect(page.getByRole('searchbox', { name: 'Search', exact: true })).toBeFocused();
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBe(375);
});

test.describe('without JavaScript', () => {
    test.use({ javaScriptEnabled: false });
    test('retains branded styling, details and a working home link', async ({ page }) => {
        expect((await page.goto(missing)).status()).toBe(404);
        await expect(heading(page, 'Not Found')).toBeVisible();
        await expect(page.locator('#docfx-http-error')).toHaveCSS('padding-top', '24px');
        await page.getByText('Technical details').click();
        await expect(page.getByText('404 Not Found', { exact: true })).toBeVisible();
        await expect(back(page)).toBeHidden();
        await page.getByRole('link', { name: 'Documentation home' }).click();
        await expect(heading(page, 'Concept guide')).toBeVisible();
    });
});

test('supported HTTP statuses and applicable headers are retained', async ({ request }) => {
    const statuses = {
        400: 'Bad Request', 401: 'Unauthorized', 403: 'Forbidden', 404: 'Not Found',
        405: 'Method Not Allowed', 410: 'Gone', 429: 'Too Many Requests',
        500: 'Internal Server Error', 502: 'Bad Gateway', 503: 'Service Unavailable', 504: 'Gateway Timeout'
    };
    for (const [code, title] of Object.entries(statuses)) {
        const response = await request.get('/_status/' + code + '.html', { maxRedirects: 0 });
        expect(response.status()).toBe(Number(code));
        expect(response.headers()['content-type']).toContain('text/html');
        expect(response.headers()['cache-control']).toContain('no-store');
        expect(response.headers().location).toBeUndefined();
        expect(await response.text()).toContain('<h1>' + title + '</h1>');
        if (code === '401') expect(response.headers()['www-authenticate']).toContain('Fixture documentation');
        if (code === '405') expect(response.headers().allow).toBe('GET, HEAD');
        if (code === '429') expect(response.headers()['retry-after']).toBe('30');
        if (code === '503') expect(response.headers()['retry-after']).toBe('60');
    }
    expect((await request.post('/index.html')).status()).toBe(405);
    const range = await request.get('/index.html', { headers: { range: 'bytes=99999999-' } });
    expect(range.status()).toBe(416);
    expect(range.headers()['content-range']).toMatch(/^bytes \*\/\d+$/);
    expect(await range.text()).toContain('<h1>Range Not Satisfiable</h1>');
    const head = await request.head(missing);
    expect(head.status()).toBe(404);
    expect(await head.text()).toBe('');

    for (const [path, headers] of [
        ['/public/missing-01234567.js', {}], ['/_docfx-errors/404.html', {}],
        [missing, { accept: 'application/json' }], [missing, { 'sec-fetch-dest': 'script' }]
    ]) {
        const response = await request.get(path, { headers });
        expect(response.status()).toBe(404);
        expect(response.headers()['content-type']).toContain('text/plain');
        expect(response.headers()['cache-control']).toContain('no-store');
        expect(await response.text()).not.toContain('docfx-http-error');
    }
});

test('retry is explicit and opens the original URL', async ({ page }) => {
    const url = '/_status/503.html?source=retry';
    expect((await page.goto(url)).status()).toBe(503);
    const retry = page.getByRole('button', { name: 'Retry' });
    const navigation = page.waitForResponse(response => response.request().isNavigationRequest());
    await retry.click();
    expect((await navigation).status()).toBe(503);
    await expect(page).toHaveURL(url);
});

test('the generated server brands errors for sites with a single TFM', async ({ page, request }) => {
    const origin = process.env.DOCFX_TEST_SINGLE_ORIGIN;
    expect(origin).toBeTruthy();
    const manifest = await (await request.get(origin + '/framework-views.json')).json();
    expect(manifest.viewOrder).toEqual(['net-11.0']);
    expect((await page.goto(origin + missing)).status()).toBe(404);
    await expect(heading(page, 'Not Found')).toBeVisible();
    await expect(alternatives(page)).toHaveCount(0);
    await page.getByRole('link', { name: 'Documentation home' }).click();
    await expect(heading(page, 'Concept guide')).toBeVisible();
});
