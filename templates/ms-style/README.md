# ms-style

`ms-style` is a small compatibility overlay for DocFX's built-in `default` and `modern` templates.

It keeps DocFX's managed-reference preprocessing, search, navigation, themes, contribution links, and custom-template merge behavior while bringing the API reading surface closer to Microsoft Learn:

- type-first headings such as `DateTime Struct`;
- a `Definition` section with Namespace, Assemblies, and Source facts;
- a narrow, readable API article column with persistent navigation rails;
- Learn-like member summary tables with Name and Description columns;
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
