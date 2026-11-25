# ms-style

`ms-style` is a small compatibility overlay for DocFX's built-in `default` and `modern` templates.

It keeps DocFX's managed-reference preprocessing, search, navigation, themes, contribution links, and custom-template merge behavior while bringing the API reading surface closer to Microsoft Learn:

- type-first headings such as `DateTime Struct`;
- a `Definition` section with Namespace, Assemblies, and Source facts;
- a narrow, readable API article column with a persistent right rail on wide screens and an inline article outline on narrower desktops;
- Learn-like type/member summary tables and namespace category tables with Name and Description columns;
- same-origin JSON navigation loaded from the deployed site instead of legacy browser cache entries; and
- responsive light and dark presentation using the existing modern assets.

The global Microsoft header, product switcher, sign-in controls, telemetry, and other Learn platform chrome are intentionally outside this template's scope.

DocFX renders the documentation site; it cannot reproduce those dynamic Learn services without an application shell around the generated site.

## Use

Add the overlay after the built-in templates in `docfx.json`:

```json
{
  "build": {
    "template": [
      "default",
      "modern",
      "templates/ms-style"
    ]
  }
}
```

DocFX merges templates from left to right. Put an existing repository template before `templates/ms-style` when it should provide repository-specific partials while `ms-style` owns the shared page shell.

Put a deliberate local override after `templates/ms-style` when it must win.

For Learn-style type pages, use separate member pages in each managed-reference metadata entry:

```json
{
  "metadata": [
    {
      "src": [ /* project sources */ ],
      "dest": "api",
      "memberLayout": "separatePages"
    }
  ]
}
```

This is the only content-model migration required. Existing DocFX YAML, Markdown, TOCs, overwrite files, and repository-specific templates remain usable.

## Framework views

The opt-in [DocFX framework views generator](../../framework-views/README.md) supplies `_frameworkApi`, `_frameworkDirectory`, and `/framework-views.json`. On API pages, the template puts the framework selector above the TOC and uses the native xref map for each view to find the current API. The selector follows the configured newest-to-oldest order, keeps the reader in the current view when that is the best available choice, and reports which view it displays. Availability refers to published documentation.

Each view keeps the public API pathname and uses `?view=` for explicit selection. The query-aware NGINX configuration also exposes the native search index for the selected framework. The template applies public URLs to search destinations and their secondary labels. Without framework build metadata, the template uses the standard DocFX navigation and search.

The generated NGINX configuration serves navigation files under the configured API root per framework. Keep the top-level TOC shared by linking to API landing pages available in every view. Keep framework-specific TOCs under the API root.

The generator uses [`framework-views.compat`](framework-views.compat) to check the [template compatibility contract](../../framework-views/README.md#template-compatibility). The [regression suite](../../tests/framework-view/README.md) exercises the template as packaged in the builder image.
