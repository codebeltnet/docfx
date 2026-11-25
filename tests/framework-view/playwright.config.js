const { defineConfig } = require('@playwright/test');

const baseURL = process.env.DOCFX_TEST_ORIGIN;
if (!baseURL) throw new Error('Set DOCFX_TEST_ORIGIN or run Test-FrameworkView.ps1.');

module.exports = defineConfig({
    testDir: '.',
    use: { baseURL }
});
